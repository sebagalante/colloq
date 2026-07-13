defmodule Colloq.Bookmarks do
  @moduledoc """
  Bookmarks context: save posts for later.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Bookmarks.Bookmark

  @doc """
  Toggles a bookmark for a user on a post.
  Returns {:ok, :created} or {:ok, :deleted}.
  """
  def toggle_bookmark(user_id, post_id) do
    case Repo.get_by(Bookmark, user_id: user_id, post_id: post_id) do
      nil ->
        # Get topic_id from the post
        post = Repo.get!(Colloq.Forum.Post, post_id)

        %Bookmark{}
        |> Bookmark.changeset(%{
          user_id: user_id,
          post_id: post_id,
          topic_id: post.topic_id
        })
        |> Repo.insert()
        |> case do
          {:ok, _} -> {:ok, :created}
          {:error, changeset} -> {:error, changeset}
        end

      bookmark ->
        Repo.delete(bookmark)
        {:ok, :deleted}
    end
  end

  @doc """
  Toggles a bookmark on a whole topic (anchored to its first post).
  Returns `{:ok, :created}` or `{:ok, :deleted}`.
  """
  def toggle_topic_bookmark(user_id, %Colloq.Forum.Topic{} = topic) do
    case Repo.get_by(Bookmark, user_id: user_id, topic_id: topic.id) do
      nil ->
        post_id = topic.first_post_id || first_post_id(topic.id)

        %Bookmark{}
        |> Bookmark.changeset(%{user_id: user_id, post_id: post_id, topic_id: topic.id})
        |> Repo.insert()
        |> case do
          {:ok, _} -> {:ok, :created}
          {:error, changeset} -> {:error, changeset}
        end

      bookmark ->
        Repo.delete(bookmark)
        {:ok, :deleted}
    end
  end

  @doc "Whether the user has bookmarked the given topic."
  def topic_bookmarked?(user_id, topic_id) do
    Repo.exists?(from b in Bookmark, where: b.user_id == ^user_id and b.topic_id == ^topic_id)
  end

  defp first_post_id(topic_id) do
    Repo.one(
      from p in Colloq.Forum.Post,
        where: p.topic_id == ^topic_id,
        order_by: [asc: p.post_number],
        limit: 1,
        select: p.id
    )
  end

  @doc """
  Lists all bookmarks for a user, with post and topic preloaded.
  """
  def list_user_bookmarks(user_id) do
    from(b in Bookmark,
      where: b.user_id == ^user_id,
      order_by: [desc: b.inserted_at],
      preload: [:topic, post: :user]
    )
    |> Repo.all()
  end

  @doc """
  Returns a set of post_ids that the user has bookmarked.
  Used for rendering bookmark state in post lists.
  """
  def user_bookmarked_post_ids(user_id, post_ids) do
    from(b in Bookmark,
      where: b.user_id == ^user_id and b.post_id in ^post_ids,
      select: b.post_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Checks if a user has bookmarked a specific post.
  """
  def bookmarked?(user_id, post_id) do
    Repo.exists?(from b in Bookmark, where: b.user_id == ^user_id and b.post_id == ^post_id)
  end
end
