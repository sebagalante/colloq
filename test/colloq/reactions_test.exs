defmodule Colloq.ReactionsTest do
  use Colloq.DataCase, async: true

  alias Colloq.Reactions
  alias Colloq.Forum

  setup do
    user = insert(:user)
    other_user = insert(:user)
    category = insert(:category)
    {:ok, topic} = Forum.create_topic(user, %{"title" => "Reactions test", "category_id" => category.id, "body" => "First"})
    {:ok, post} = Forum.create_post(topic, user, %{"body" => "React to me"})

    %{user: user, other_user: other_user, topic: topic, post: post}
  end

  describe "toggle_reaction/3" do
    test "adds a reaction", %{user: user, post: post} do
      {:ok, :added, reaction} = Reactions.toggle_reaction(post.id, user.id, "👍")

      assert reaction.emoji == "👍"
      assert reaction.post_id == post.id
      assert reaction.user_id == user.id
    end

    test "removes an existing reaction on second toggle", %{user: user, post: post} do
      {:ok, :added, _} = Reactions.toggle_reaction(post.id, user.id, "👍")
      {:ok, :removed, nil} = Reactions.toggle_reaction(post.id, user.id, "👍")

      assert Reactions.reaction_counts(post.id) == %{}
    end

    test "updates the post reactions_count", %{user: user, other_user: other_user, post: post} do
      Reactions.toggle_reaction(post.id, user.id, "👍")
      Reactions.toggle_reaction(post.id, other_user.id, "👍")
      Reactions.toggle_reaction(post.id, user.id, "❤️")

      updated_post = Repo.get!(Colloq.Forum.Post, post.id)
      assert updated_post.reactions_count == 3
    end

    test "allows different emojis from the same user", %{user: user, post: post} do
      {:ok, :added, _} = Reactions.toggle_reaction(post.id, user.id, "👍")
      {:ok, :added, _} = Reactions.toggle_reaction(post.id, user.id, "❤️")

      counts = Reactions.reaction_counts(post.id)
      assert counts["👍"] == 1
      assert counts["❤️"] == 1
    end
  end

  describe "reaction_counts/1" do
    test "returns a map of emoji => count", %{user: user, other_user: other_user, post: post} do
      Reactions.toggle_reaction(post.id, user.id, "👍")
      Reactions.toggle_reaction(post.id, other_user.id, "👍")
      Reactions.toggle_reaction(post.id, user.id, "🔥")

      counts = Reactions.reaction_counts(post.id)
      assert counts["👍"] == 2
      assert counts["🔥"] == 1
    end

    test "returns empty map for post with no reactions", %{post: post} do
      assert Reactions.reaction_counts(post.id) == %{}
    end
  end

  describe "user_reactions/2" do
    test "returns a MapSet of emojis the user reacted with", %{user: user, post: post} do
      Reactions.toggle_reaction(post.id, user.id, "👍")
      Reactions.toggle_reaction(post.id, user.id, "❤️")

      emojis = Reactions.user_reactions(post.id, user.id)
      assert MapSet.member?(emojis, "👍")
      assert MapSet.member?(emojis, "❤️")
      assert MapSet.size(emojis) == 2
    end

    test "returns empty MapSet for user with no reactions", %{user: user, post: post} do
      emojis = Reactions.user_reactions(post.id, user.id)
      assert MapSet.size(emojis) == 0
    end

    test "does not include emojis from other users", %{user: user, other_user: other_user, post: post} do
      Reactions.toggle_reaction(post.id, other_user.id, "👍")
      Reactions.toggle_reaction(post.id, user.id, "❤️")

      user_emojis = Reactions.user_reactions(post.id, user.id)
      assert MapSet.member?(user_emojis, "❤️")
      refute MapSet.member?(user_emojis, "👍")
    end
  end
end
