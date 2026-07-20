defmodule Colloq.Reactions do
  @moduledoc """
  Emoji reaction context for posts.

  Allows users to react to any post with an emoji.
  Implements toggle behavior: removes the reaction if it already exists, adds it otherwise.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Reactions.Reaction
  alias Colloq.Forum.Post

  @doc """
  Sets a user's reaction on a post. One reaction per `[post_id, user_id]`:

    * no existing reaction → the emoji is added
    * same emoji again → the reaction is removed (toggle off)
    * a different emoji → it **replaces** the previous one

  Reacting to your own post is refused with `{:error, :own_post}`.

  Broadcasts a `"reaction_updated"` event to the topic channel.

  Returns `{:ok, :added, reaction}`, `{:ok, :removed, nil}`, or `{:error, reason}`.
  """
  def toggle_reaction(post_id, user_id, emoji) when is_binary(emoji) do
    post = Repo.get!(Post, post_id)

    if post.user_id == user_id do
      {:error, :own_post}
    else
      result = apply_reaction(post_id, user_id, emoji)

      update_post_counter(post_id)

      ColloqWeb.Endpoint.broadcast("forum:topic:#{post.topic_id}", "reaction_updated", %{
        post_id: post_id,
        counts: reaction_counts(post_id)
      })

      # Notify the post's author when someone else reacts to it.
      if match?({:ok, :added, _}, result), do: notify_reaction(post, user_id, emoji)

      result
    end
  rescue
    Ecto.ConstraintError -> {:error, :already_reacted}
  end

  # The user's single reaction row for this post, whatever emoji it holds.
  defp apply_reaction(post_id, user_id, emoji) do
    existing =
      Reaction
      |> where(post_id: ^post_id, user_id: ^user_id)
      |> Repo.one()

    case existing do
      nil ->
        {:ok, reaction} =
          %Reaction{}
          |> Reaction.changeset(%{post_id: post_id, user_id: user_id, emoji: emoji})
          |> Repo.insert()

        {:ok, :added, reaction}

      %Reaction{emoji: ^emoji} = reaction ->
        # Same emoji: toggle it off.
        Repo.delete!(reaction)
        {:ok, :removed, nil}

      reaction ->
        # Different emoji: switch, rather than stacking a second reaction.
        {:ok, updated} =
          reaction
          |> Reaction.changeset(%{emoji: emoji})
          |> Repo.update()

        {:ok, :added, updated}
    end
  end

  defp notify_reaction(%Post{user_id: author_id, topic_id: topic_id, id: post_id}, user_id, emoji)
       when author_id != user_id do
    actor = Colloq.Accounts.get_user(user_id)

    if actor do
      Colloq.Notifications.create_notification(%{
        user_id: author_id,
        type: "reaction",
        title: "#{actor.username} reaccionó #{emoji}",
        body: "",
        data: %{
          "topic_id" => topic_id,
          "post_id" => post_id,
          "actor_id" => user_id,
          "actor_username" => actor.username
        }
      })
    end
  rescue
    _ -> :ok
  end

  defp notify_reaction(_post, _user_id, _emoji), do: :ok

  @doc """
  Returns a map of emoji counts for a post.

  ## Example

      iex> reaction_counts(42)
      %{"👍" => 5, "❤️" => 3}
  """
  def reaction_counts(post_id) do
    Reaction
    |> where([r], r.post_id == ^post_id)
    |> group_by([r], r.emoji)
    |> select([r], {r.emoji, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Reaction counts for many posts in one query: `%{post_id => %{emoji => count}}`.

  Calling `reaction_counts/1` in a loop costs one query per post, which is what
  the profile page used to do for every post it listed. Posts with no reactions
  are absent from the map — callers should default with `Map.get(map, id, %{})`.
  """
  def reaction_counts_for(post_ids) when is_list(post_ids) do
    Reaction
    |> where([r], r.post_id in ^post_ids)
    |> group_by([r], [r.post_id, r.emoji])
    |> select([r], {r.post_id, r.emoji, count(r.id)})
    |> Repo.all()
    |> Enum.group_by(fn {post_id, _, _} -> post_id end, fn {_, emoji, count} -> {emoji, count} end)
    |> Map.new(fn {post_id, pairs} -> {post_id, Map.new(pairs)} end)
  end

  @doc """
  Returns the list of users who reacted with a specific emoji.

  ## Example

      iex> who_reacted(42, "👍")
      [%User{username: "john"}, ...]
  """
  def who_reacted(post_id, emoji) when is_binary(emoji) do
    Reaction
    |> where([r], r.post_id == ^post_id and r.emoji == ^emoji)
    |> preload(:user)
    |> Repo.all()
    |> Enum.map(& &1.user)
  end

  @doc """
  Returns the set of emojis a user has already reacted with on a post.

  ## Example

      iex> user_reactions(42, 7)
      MapSet.new(["👍", "❤️"])
  """
  def user_reactions(post_id, user_id) do
    Reaction
    |> where([r], r.post_id == ^post_id and r.user_id == ^user_id)
    |> select([r], r.emoji)
    |> Repo.all()
    |> MapSet.new()
  end

  defp update_post_counter(post_id) do
    count =
      Reaction
      |> where([r], r.post_id == ^post_id)
      |> Repo.aggregate(:count, :id)

    Post
    |> where(id: ^post_id)
    |> Repo.update_all(set: [reactions_count: count])
  end
end
