defmodule Colloq.PrunePostsWorkerTest do
  @moduledoc """
  Permanent deletion of soft-deleted posts.

  The interesting cases are the refusals: `posts.parent_id` is SET NULL, so
  purging a parent promotes its replies to root comments, and `flags.post_id`
  cascades, so purging a flagged post deletes the open moderation case.
  """
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.Forum.Post
  alias Colloq.Moderation
  alias Colloq.Workers.PrunePostsWorker

  @moderated PrunePostsWorker.retention_days().moderated
  @self_deleted PrunePostsWorker.retention_days().self_deleted

  setup do
    topic = insert(:topic, category: insert(:category), user: insert(:user))
    %{topic: topic, author: insert(:user)}
  end

  defp post_deleted(ctx, opts) do
    days = Keyword.fetch!(opts, :days_ago)
    hidden = Keyword.get(opts, :hidden, true)

    insert(:post,
      topic: ctx.topic,
      user: ctx.author,
      post_number: System.unique_integer([:positive, :monotonic]),
      body: "<p>viejo</p>",
      hidden: hidden,
      deleted_at: DateTime.add(DateTime.utc_now(), -days, :day)
    )
  end

  defp run, do: PrunePostsWorker.perform(%Oban.Job{args: %{}})

  describe "retention" do
    test "a moderation hide past the window is purged", ctx do
      post = post_deleted(ctx, days_ago: @moderated + 1, hidden: true)

      assert {:ok, %{deleted: 1}} = run()
      refute Repo.get(Post, post.id)
    end

    test "a moderation hide inside the window is kept", ctx do
      post = post_deleted(ctx, days_ago: @moderated - 1, hidden: true)

      assert {:ok, %{deleted: 0}} = run()
      assert Repo.get(Post, post.id)
    end

    test "a self-deletion is purged on the shorter window", ctx do
      post = post_deleted(ctx, days_ago: @self_deleted + 1, hidden: false)

      assert {:ok, %{deleted: 1}} = run()
      refute Repo.get(Post, post.id)
    end

    test "a self-deletion inside its window is kept", ctx do
      post = post_deleted(ctx, days_ago: @self_deleted - 1, hidden: false)

      assert {:ok, %{deleted: 0}} = run()
      assert Repo.get(Post, post.id)
    end

    test "a live post is never touched, however old", ctx do
      post =
        insert(:post,
          topic: ctx.topic,
          user: ctx.author,
          post_number: 1,
          inserted_at: DateTime.add(DateTime.utc_now(), -500, :day)
        )

      assert {:ok, %{deleted: 0}} = run()
      assert Repo.get(Post, post.id)
    end
  end

  describe "refusals" do
    test "a post with an unresolved flag is kept", ctx do
      post = post_deleted(ctx, days_ago: @moderated + 5)
      {:ok, _} = Moderation.flag_post(post.id, ctx.author.id, "spam")

      assert {:ok, %{deleted: 0}} = run()
      assert Repo.get(Post, post.id), "purging it would delete the open case with it"
    end

    test "a post whose flag was resolved is purged", ctx do
      post = post_deleted(ctx, days_ago: @moderated + 5)
      {:ok, flag} = Moderation.flag_post(post.id, ctx.author.id, "spam")
      {:ok, _} = Moderation.resolve_flag(flag.id, ctx.author.id, "ok")

      assert {:ok, %{deleted: 1}} = run()
      refute Repo.get(Post, post.id)
    end

    test "a post with replies is kept, so they aren't promoted to root", ctx do
      parent = post_deleted(ctx, days_ago: @moderated + 5)

      reply =
        insert(:post,
          topic: ctx.topic,
          user: ctx.author,
          post_number: System.unique_integer([:positive, :monotonic]),
          parent_id: parent.id,
          body: "<p>respuesta viva</p>"
        )

      assert {:ok, %{deleted: 0}} = run()
      assert Repo.get(Post, parent.id)
      assert Repo.get(Post, reply.id).parent_id == parent.id, "the reply must keep its parent"
    end

    test "once the replies are gone the parent becomes purgeable", ctx do
      parent = post_deleted(ctx, days_ago: @moderated + 5)

      reply =
        insert(:post,
          topic: ctx.topic,
          user: ctx.author,
          post_number: System.unique_integer([:positive, :monotonic]),
          parent_id: parent.id
        )

      assert {:ok, %{deleted: 0}} = run()

      Repo.delete!(reply)

      assert {:ok, %{deleted: 1}} = run()
      refute Repo.get(Post, parent.id)
    end
  end

  describe "classifier history" do
    test "a score outlives the post it scored", ctx do
      post = post_deleted(ctx, days_ago: @moderated + 5)

      {:ok, classification} =
        Moderation.record_spam_classification(%{
          post_id: post.id,
          user_id: ctx.author.id,
          score: 0.97,
          threshold: 0.9,
          would_flag: true,
          mode: "shadow",
          acted: false
        })

      assert {:ok, %{deleted: 1}} = run()

      kept = Repo.get(Colloq.Moderation.SpamClassification, classification.id)

      assert kept, "purging the post must not erase the dashboard's history"
      assert kept.score == 0.97
      assert is_nil(kept.post_id), "the link is nilified, not cascaded"
    end

    test "the dashboard still renders with an orphaned score", ctx do
      post = post_deleted(ctx, days_ago: @moderated + 5)

      {:ok, _} =
        Moderation.record_spam_classification(%{
          post_id: post.id,
          user_id: ctx.author.id,
          score: 0.97,
          threshold: 0.9,
          would_flag: true,
          mode: "shadow",
          acted: false
        })

      run()

      # recent_spam_classifications preloads :post; a nil post must not crash it.
      assert [row] = Moderation.recent_spam_classifications(10)
      assert is_nil(row.post)
      assert Moderation.spam_stats(7).total == 1
    end
  end

  describe "dry run" do
    test "reports without deleting", ctx do
      post = post_deleted(ctx, days_ago: @moderated + 5)

      assert {:ok, %{would_delete: 1}} =
               PrunePostsWorker.perform(%Oban.Job{args: %{"dry_run" => true}})

      assert Repo.get(Post, post.id)
    end
  end
end
