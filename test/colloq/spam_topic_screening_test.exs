defmodule Colloq.SpamTopicScreeningTest do
  @moduledoc """
  Screening covers the topic title, not just the body.

  Topic creation always enqueued a check on the opening post, but the worker
  only ever looked at `post.body` — so a spam topic put its payload in the
  *title* and sailed through: body "hola" scores 0.02 and matches no blocked
  word, while the title alone scores 0.999.
  """
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.{Forum, Moderation, Repo, SiteSettings}
  alias Colloq.Workers.SpamDetectorWorker

  setup do
    SiteSettings.put("blocked_words", "viagra, casino", type: "string", group: "forum")

    # Hiding a post flags it as the "sistema" account. Without that user the
    # worker falls back to a hardcoded user id 1 and the insert fails on the
    # foreign key, which aborts the surrounding transaction.
    insert(:user, username: "sistema")

    author = insert(:user, trust_level: 1)
    category = insert(:category)

    %{author: author, category: category}
  end

  defp perform(post), do: SpamDetectorWorker.perform(%Oban.Job{args: %{"post_id" => post.id}})

  defp opening_post(topic) do
    Repo.one(from p in Forum.Post, where: p.topic_id == ^topic.id, order_by: p.post_number, limit: 1)
  end

  test "a blocked word in the title is caught even with a clean body", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "COMPRA VIAGRA BARATO",
        "body" => "<p>hola muchachos</p>",
        "category_id" => ctx.category.id
      })

    post = opening_post(topic)

    assert {:ok, "spam detectado: palabras_bloqueadas"} = perform(post)
    assert Repo.get(Forum.Post, post.id).hidden
  end

  test "an ordinary topic is left alone", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Qué les pareció el mediocampo",
        "body" => "<p>me pareció que ganamos equilibrio</p>",
        "category_id" => ctx.category.id
      })

    post = opening_post(topic)

    assert perform(post) == :ok
    refute Repo.get(Forum.Post, post.id).hidden
  end

  test "a reply is screened on its body alone, not its topic's title", ctx do
    # Otherwise every reply in a topic whose title happens to contain a blocked
    # word would be hidden, including replies calling it out.
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Cuidado con el casino que linkearon",
        "body" => "<p>ojo con eso</p>",
        "category_id" => ctx.category.id
      })

    reply = insert(:post, topic: topic, user: ctx.author, post_number: 2, body: "<p>gracias por avisar</p>")

    assert perform(reply) == :ok
    refute Repo.get(Forum.Post, reply.id).hidden
  end

  test "markup is stripped before matching, so tag names can't match", ctx do
    SiteSettings.put("blocked_words", "strong, href", type: "string", group: "forum")

    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Un partidazo",
        "body" => ~s(<p><strong><a href="https://ejemplo.test">mirá</a></strong></p>),
        "category_id" => ctx.category.id
      })

    post = opening_post(topic)

    assert perform(post) == :ok, "matched the HTML rather than the text"
    refute Repo.get(Forum.Post, post.id).hidden
  end

  test "creating the topic screens it, with no manual worker call", ctx do
    # Oban runs `testing: :inline` here, so creating the topic executes the
    # queued job immediately. Asserting on the *effect* rather than on an
    # oban_jobs row is what proves the automatic path works end to end — no
    # perform/1 anywhere in this test.
    {:ok, spam} =
      Forum.create_topic(ctx.author, %{
        "title" => "VIAGRA al mejor precio",
        "body" => "<p>hola</p>",
        "category_id" => ctx.category.id
      })

    {:ok, ok_topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Análisis del partido",
        "body" => "<p>jugamos bien</p>",
        "category_id" => ctx.category.id
      })

    assert Repo.get(Forum.Post, opening_post(spam).id).hidden,
           "a spam-titled topic should be hidden by creation alone"

    refute Repo.get(Forum.Post, opening_post(ok_topic).id).hidden
  end

  test "a trusted author's topic is never screened", ctx do
    trusted = insert(:user, trust_level: 3)

    {:ok, topic} =
      Forum.create_topic(trusted, %{
        "title" => "COMPRA VIAGRA BARATO",
        "body" => "<p>hola</p>",
        "category_id" => ctx.category.id
      })

    post = opening_post(topic)

    assert {:discard, _} = perform(post)
    refute Repo.get(Forum.Post, post.id).hidden
  end

  test "blocked_word_hit sees the title through the worker's text builder", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Vengan al CASINO",
        "body" => "<p>nada</p>",
        "category_id" => ctx.category.id
      })

    post = opening_post(topic) |> Repo.preload(:topic)

    # The title is what carries the hit; the body on its own is clean.
    assert Moderation.blocked_word_hit(post.topic.title) == "casino"
    refute Moderation.blocked_word_hit(HtmlSanitizeEx.strip_tags(post.body))
  end
end
