defmodule Colloq.Forum do
  @moduledoc """
  Forum context: Topics, Posts, Categories, Search.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Forum.{Topic, Post, Category}
  alias Colloq.Accounts

  # --- TOPICS ---

  @doc """
  List topics with pagination.
  """
  def list_topics(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    category_id = Keyword.get(opts, :category_id)

    Topic
    |> filter_by_category(category_id)
    |> order_by(desc: :bumped_at)
    |> preload([:category, :user, :last_post])
    |> Repo.paginate(page: page, page_size: per_page)
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, category_id), do: where(query, category_id: ^category_id)

  @doc """
  Get a single topic.
  """
  def get_topic!(id) do
    Topic
    |> preload([:category, :user, posts: [:user]])
    |> Repo.get!(id)
  end

  @doc """
  Create a new topic (first post).
  """
  def create_topic(%Accounts.User{} = user, attrs) do
    Repo.transaction(fn ->
      # Create topic
      topic_attrs = Map.merge(attrs, %{"user_id" => user.id, "bumped_at" => DateTime.utc_now()})

      {:ok, topic} =
        %Topic{}
        |> Topic.changeset(topic_attrs)
        |> Repo.insert()

      # Create first post
      post_attrs = %{
        "topic_id" => topic.id,
        "user_id" => user.id,
        "body" => attrs["body"] || "",
        "body_json" => attrs["body_json"],
        "post_number" => 1
      }

      {:ok, post} =
        %Post{}
        |> Post.changeset(post_attrs)
        |> Repo.insert()

      # Update topic with first_post_id
      topic |> Ecto.Changeset.change(first_post_id: post.id) |> Repo.update!()

      # Increment user post count
      Accounts.increment_posts_count(user)

      # Broadcast
      ColloqWeb.Endpoint.broadcast("forum:topic_list", "topic_created", %{
        topic_id: topic.id,
        category_id: topic.category_id
      })

      %{topic | posts: [post]}
    end)
  end

  @doc """
  Reply to a topic (create post).
  """
  def create_post(%Topic{} = topic, %Accounts.User{} = user, attrs) do
    post_number = topic.posts_count + 1

    post_attrs = %{
      "topic_id" => topic.id,
      "user_id" => user.id,
      "body" => attrs["body"],
      "body_json" => attrs["body_json"],
      "post_number" => post_number
    }

    Repo.transaction(fn ->
      {:ok, post} =
        %Post{}
        |> Post.changeset(post_attrs)
        |> Repo.insert()

      # Update topic bump
      topic
      |> Ecto.Changeset.change(
        posts_count: post_number,
        bumped_at: DateTime.utc_now(),
        last_post_id: post.id
      )
      |> Repo.update!()

      Accounts.increment_posts_count(user)

      # Auto-close at 50k posts (Discourse model)
      if post_number >= 50_000 do
        close_topic(topic, "post_limit")
      end

      # Broadcast
      ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "new_post", %{
        post_id: post.id,
        user_id: user.id
      })

      post
    end)
  end

  @doc """
  Close a topic.
  """
  def close_topic(%Topic{} = topic, reason) do
    topic
    |> Ecto.Changeset.change(
      closed: true,
      closed_at: DateTime.utc_now(),
      closed_reason: reason
    )
    |> Repo.update()
  end

  @doc """
  Archive a topic (manual or automation).
  """
  def archive_topic(%Topic{} = topic) do
    topic
    |> Ecto.Changeset.change(
      archived: true,
      archived_at: DateTime.utc_now()
    )
    |> Repo.update()
  end

  @doc """
  Set match mode on a match thread.
  """
  def set_match_mode(%Topic{} = topic, mode) when mode in ["prematch", "live", "fulltime"] do
    topic
    |> Ecto.Changeset.change(match_mode: mode)
    |> Repo.update()
  end

  # --- POSTS ---

  @doc """
  Get a post.
  """
  def get_post!(id), do: Repo.get!(Post, id) |> Repo.preload([:user, :topic])

  @doc """
  Update a post.
  """
  def update_post(%Post{} = post, attrs) do
    post
    |> Post.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Soft-delete (hide) a post.
  """
  def delete_post(%Post{} = post) do
    post
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  Increment view count (fire-and-forget).
  """
  def increment_post_view(%Post{} = post) do
    Post
    |> where(id: ^post.id)
    |> Repo.update_all(inc: [view_count: 1])
  end

  # --- CATEGORIES ---

  def list_categories do
    Category
    |> order_by(:position)
    |> Repo.all()
  end

  def get_category!(id), do: Repo.get!(Category, id)

  # --- SEARCH (ParadeDB BM25) ---

  @doc """
  Search posts using ParadeDB BM25.
  """
  def search_posts(query_string, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    # Use raw SQL with pg_search
    sql = """
    SELECT p.id, p.body, p.inserted_at, p.topic_id,
           paradedb.score(p.id) as search_rank
    FROM posts p
    WHERE p.deleted_at IS NULL
      AND p.id @@@ paradedb.fuzzy_phrase('body', $1)
    ORDER BY search_rank DESC
    LIMIT $2 OFFSET $3
    """

    result = Ecto.Adapters.SQL.query!(Repo, sql, [query_string, limit, offset])

    Enum.map(result.rows, fn row ->
      %{
        id: Enum.at(row, 0),
        body: Enum.at(row, 1),
        inserted_at: Enum.at(row, 2),
        topic_id: Enum.at(row, 3),
        rank: Enum.at(row, 4)
      }
    end)
  end

  @doc """
  Search topics using ParadeDB BM25.
  """
  def search_topics(query_string, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    sql = """
    SELECT t.id, t.title, t.slug, t.inserted_at,
           paradedb.score(t.id) as search_rank
    FROM topics t
    WHERE t.archived = false
      AND t.id @@@ paradedb.fuzzy_phrase('title', $1)
    ORDER BY search_rank DESC
    LIMIT $2
    """

    result = Ecto.Adapters.SQL.query!(Repo, sql, [query_string, limit])

    Enum.map(result.rows, fn row ->
      %{
        id: Enum.at(row, 0),
        title: Enum.at(row, 1),
        slug: Enum.at(row, 2),
        inserted_at: Enum.at(row, 3),
        rank: Enum.at(row, 4)
      }
    end)
  rescue
    _ -> []  # Fallback if pg_search not yet installed
  end
end
