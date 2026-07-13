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
  Toggles a reaction (on/off) for a user on a post.

  If the user already reacted with that emoji, the reaction is removed.
  Otherwise it is created. Respects the unique constraint `[post_id, user_id, emoji]`.

  Broadcasts a `"reaction_updated"` event to the topic channel.

  Returns `{:ok, :added, reaction}` or `{:ok, :removed, nil}`.
  """
  def toggle_reaction(post_id, user_id, emoji) when is_binary(emoji) do
    existing =
      Reaction
      |> where(post_id: ^post_id, user_id: ^user_id, emoji: ^emoji)
      |> Repo.one()

    result =
      case existing do
        nil ->
          {:ok, reaction} =
            %Reaction{}
            |> Reaction.changeset(%{
              post_id: post_id,
              user_id: user_id,
              emoji: emoji
            })
            |> Repo.insert()

          {:ok, :added, reaction}

        reaction ->
          Repo.delete!(reaction)
          {:ok, :removed, nil}
      end

    # Update reaction counter on the post
    update_post_counter(post_id)

    # Broadcast real-time update to the topic channel
    post = Repo.get!(Post, post_id)
    counts = reaction_counts(post_id)
    ColloqWeb.Endpoint.broadcast("forum:topic:#{post.topic_id}", "reaction_updated", %{
      post_id: post_id,
      counts: counts
    })

    # Notify the post's author when someone else reacts to it.
    if match?({:ok, :added, _}, result), do: notify_reaction(post, user_id, emoji)

    result
  rescue
    Ecto.ConstraintError -> {:error, :already_reacted}
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
