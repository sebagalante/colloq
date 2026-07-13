defmodule Colloq.ForumTest do
  use Colloq.DataCase, async: true

  alias Colloq.Forum
  alias Colloq.Forum.{Topic, Post}

  describe "create_topic/2" do
    test "creates a topic with a first post" do
      user = insert(:user)
      category = insert(:category)

      {:ok, topic} =
        Forum.create_topic(user, %{
          "title" => "My new topic",
          "category_id" => category.id,
          "body" => "Hello world"
        })

      assert topic.title == "My new topic"
      assert topic.slug == "my-new-topic"
      assert topic.user_id == user.id
      assert topic.category_id == category.id
      assert length(topic.posts) == 1

      first_post = hd(topic.posts)
      assert first_post.body == "Hello world"
      assert first_post.post_number == 1
      assert first_post.user_id == user.id
    end

    test "validates title length" do
      user = insert(:user)
      category = insert(:category)

      {:error, changeset} =
        Forum.create_topic(user, %{
          "title" => "Hi",
          "category_id" => category.id,
          "body" => "Body"
        })

      assert "should be at least 5 character(s)" in errors_on(changeset).title
    end
  end

  describe "create_post/3" do
    test "creates a top-level reply to a topic" do
      user = insert(:user)
      category = insert(:category)
      {:ok, topic} = Forum.create_topic(user, %{"title" => "Test topic", "category_id" => category.id, "body" => "First"})

      {:ok, post} = Forum.create_post(topic, user, %{"body" => "Reply body"})

      assert post.body == "Reply body"
      assert post.post_number == 2
      assert post.parent_id == nil
    end

    test "auto-closes topic at 50k posts" do
      user = insert(:user)
      category = insert(:category)
      {:ok, topic} = Forum.create_topic(user, %{"title" => "Test topic", "category_id" => category.id, "body" => "First"})

      # Simulate being at 49,999 posts
      topic
      |> Ecto.Changeset.change(posts_count: 49_999)
      |> Repo.update!()

      {:ok, _post} = Forum.create_post(topic, user, %{"body" => "Post 50k"})

      updated_topic = Repo.get!(Topic, topic.id)
      assert updated_topic.closed == true
      assert updated_topic.closed_reason == "post_limit"
    end
  end

  describe "create_reply/4 — nested replies" do
    setup do
      user = insert(:user)
      category = insert(:category)
      {:ok, topic} = Forum.create_topic(user, %{"title" => "Test topic", "category_id" => category.id, "body" => "First post"})
      {:ok, parent_post} = Forum.create_post(topic, user, %{"body" => "Parent post"})

      %{user: user, topic: topic, parent_post: parent_post}
    end

    test "creates a nested reply with parent_id", %{user: user, topic: topic, parent_post: parent_post} do
      {:ok, reply} = Forum.create_reply(topic, user, parent_post, %{"body" => "Nested reply"})

      assert reply.body == "Nested reply"
      assert reply.parent_id == parent_post.id
      assert reply.post_number == 3
    end

    test "rejects parent from a different topic", %{user: user, topic: topic} do
      other_user = insert(:user)
      other_category = insert(:category)
      {:ok, other_topic} = Forum.create_topic(other_user, %{"title" => "Other topic", "category_id" => other_category.id, "body" => "Other first"})
      {:ok, other_post} = Forum.create_post(other_topic, other_user, %{"body" => "Other post"})

      {:error, :invalid_parent} = Forum.create_reply(topic, user, other_post, %{"body" => "Cross-topic reply"})
    end
  end

  describe "get_topic!/1 — nested tree" do
    setup do
      user = insert(:user)
      category = insert(:category)
      {:ok, topic} = Forum.create_topic(user, %{"title" => "Tree test", "category_id" => category.id, "body" => "Root post"})

      %{user: user, topic: topic}
    end

    test "returns root posts with nested replies", %{user: user, topic: topic} do
      {:ok, post1} = Forum.create_post(topic, user, %{"body" => "Top-level reply 1"})
      {:ok, reply1} = Forum.create_reply(topic, user, post1, %{"body" => "Nested reply to post1"})
      {:ok, reply2} = Forum.create_reply(topic, user, reply1, %{"body" => "Deeply nested reply"})
      {:ok, post2} = Forum.create_post(topic, user, %{"body" => "Top-level reply 2"})

      loaded_topic = Forum.get_topic!(topic.id)
      root_posts = loaded_topic.posts

      # Root posts: first post + post1 + post2 = 3
      assert length(root_posts) == 3

      # post1 should have reply1 as a nested reply
      post1_loaded = Enum.find(root_posts, &(&1.id == post1.id))
      assert length(post1_loaded.replies) == 1
      reply1_loaded = hd(post1_loaded.replies)
      assert reply1_loaded.body == "Nested reply to post1"

      # reply1 should have reply2 as a deeply nested reply
      assert length(reply1_loaded.replies) == 1
      reply2_loaded = hd(reply1_loaded.replies)
      assert reply2_loaded.body == "Deeply nested reply"

      # post2 should have no replies
      post2_loaded = Enum.find(root_posts, &(&1.id == post2.id))
      assert post2_loaded.replies == []
    end

    test "excludes soft-deleted posts", %{user: user, topic: topic} do
      {:ok, post1} = Forum.create_post(topic, user, %{"body" => "Will be deleted"})
      {:ok, _post2} = Forum.create_post(topic, user, %{"body" => "Survives"})

      Forum.delete_post(post1)

      loaded_topic = Forum.get_topic!(topic.id)
      root_posts = loaded_topic.posts

      # Root posts: first post + post2 = 2 (post1 excluded)
      assert length(root_posts) == 2
      refute Enum.any?(root_posts, &(&1.id == post1.id))
    end
  end
end
