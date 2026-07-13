defmodule Colloq.Forum do
  @moduledoc """
  Forum context: Topics, Posts, Categories, Search.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Forum.{Topic, Post, Category}
  alias Colloq.Accounts

  alias Colloq.Pagination

  # --- TOPICS ---

  @doc """
  Lists topics with pagination, ordered by most recent bump.

  ## Options

    * `:page` - page number (default 1)
    * `:per_page` - results per page (default 25)
    * `:category_id` - filter by category
    * `:blocked_ids` - MapSet of user IDs to exclude (blocked users)

  Returns a `%Pagination{}` struct with `:entries`, `:page`, `:total_pages`, etc.
  """
  def list_topics(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    category_id = Keyword.get(opts, :category_id)
    order = Keyword.get(opts, :order, :latest)
    blocked_ids = Keyword.get(opts, :blocked_ids, MapSet.new())
    blocked_list = MapSet.to_list(blocked_ids)
    muted_list = opts |> Keyword.get(:muted_topic_ids, MapSet.new()) |> MapSet.to_list()

    Topic
    |> filter_by_category(category_id)
    |> then(fn query ->
      if blocked_list != [] do
        where(query, [t], t.user_id not in ^blocked_list)
      else
        query
      end
    end)
    |> then(fn query ->
      if muted_list != [] do
        where(query, [t], t.id not in ^muted_list)
      else
        query
      end
    end)
    |> order_topics(order)
    |> preload([:category, :user, last_post: :user])
    |> Pagination.paginate(page: page, page_size: per_page)
  end

  # Pinned topics always float to the top; then the chosen ordering.
  defp order_topics(query, :top),
    do: order_by(query, [t], desc: t.pinned, desc: t.views_count, desc: t.bumped_at)

  defp order_topics(query, _latest),
    do: order_by(query, [t], desc: t.pinned, desc: t.bumped_at)

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, category_id), do: where(query, category_id: ^category_id)

  @doc """
  Gets a single topic by ID with posts nested as a reply tree.

  Soft-deleted posts are excluded. Posts from blocked users are excluded
  when `blocked_ids` is provided. Raises `Ecto.NoResultsError` if not found.

  Returns a `%Topic{}` with `:posts` containing a nested list of root posts,
  each carrying their `:replies`.
  """
  def get_topic!(id, blocked_ids \\ MapSet.new()) do
    blocked_list = MapSet.to_list(blocked_ids)

    posts =
      Post
      |> where([p], p.topic_id == ^id and is_nil(p.deleted_at))
      |> then(fn query ->
        if blocked_list != [] do
          where(query, [p], p.user_id not in ^blocked_list)
        else
          query
        end
      end)
      |> order_by(asc: :inserted_at)
      |> preload([:user, :embeds])
      |> Repo.all()

    topic =
      Topic
      |> preload([:category, :user])
      |> Repo.get!(id)

    %{topic | posts: nest_posts(posts)}
  end

  # Build a nested reply tree from a flat list of posts (correct at any depth).
  # Posts arrive ordered by inserted_at, so replies keep chronological order.
  defp nest_posts(posts) do
    children_by_parent = Enum.group_by(posts, & &1.parent_id)
    build_reply_tree(Map.get(children_by_parent, nil, []), children_by_parent)
  end

  defp build_reply_tree(nodes, children_by_parent) do
    Enum.map(nodes, fn post ->
      replies = build_reply_tree(Map.get(children_by_parent, post.id, []), children_by_parent)
      %{post | replies: replies}
    end)
  end

  @doc """
  Creates a new topic and its first post in a single transaction.

  Broadcasts a `"topic_created"` event to the `"forum:topic_list"` channel.

  Returns `{:ok, %{topic | posts: [post]}}` or `{:error, changeset}`.
  """
  def create_topic(%Accounts.User{} = user, attrs) do
    with :ok <- check_can_post(user) do
    Repo.transaction(fn ->
      # Create topic
      tag_names = attrs["tags"] || []
      topic_attrs = Map.merge(attrs, %{"user_id" => user.id, "bumped_at" => DateTime.utc_now()})

      topic =
        case %Topic{} |> Topic.changeset(topic_attrs) |> Repo.insert() do
          {:ok, t} -> t
          {:error, changeset} -> Repo.rollback(changeset)
        end

      # Create first post
      post_attrs = %{
        "topic_id" => topic.id,
        "user_id" => user.id,
        "body" => attrs["body"] || "",
        "body_json" => attrs["body_json"],
        "post_number" => 1
      }

      post =
        case %Post{} |> Post.changeset(post_attrs) |> Repo.insert() do
          {:ok, p} -> p
          {:error, changeset} -> Repo.rollback(changeset)
        end

      # Update topic with first/last post and the initial post count
      topic =
        topic
        |> Ecto.Changeset.change(first_post_id: post.id, last_post_id: post.id, posts_count: 1)
        |> Repo.update!()

      # Set tags
      if tag_names != [] do
        tags = Colloq.Tags.find_or_create_tags(tag_names)
        Colloq.Tags.set_topic_tags(topic, tags)
      end

      enqueue_embed(post)

      # Author watches their own topic by default.
      Colloq.Subscriptions.watch_if_new(user.id, topic.id)

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
  end

  # Blocks banned/suspended/silenced users from creating topics or posts.
  defp check_can_post(%Accounts.User{} = user) do
    cond do
      user.banned -> {:error, :banned}
      Accounts.User.suspended?(user) -> {:error, :suspended}
      Accounts.User.silenced?(user) -> {:error, :silenced}
      true -> :ok
    end
  end

  @doc """
  Creates a reply (post) in a topic.

  Auto-closes the topic at 50,000 posts. Broadcasts a `"new_post"` event
  to the topic channel.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%Topic{} = topic, %Accounts.User{} = user, attrs) do
    with :ok <- check_can_post(user) do
    # Derive the next post number from the real max (not posts_count, which can
    # drift and cause a unique-constraint collision on (topic_id, post_number)).
    max_number = Repo.one(from(p in Post, where: p.topic_id == ^topic.id, select: max(p.post_number))) || 0
    post_number = max_number + 1

    post_attrs = %{
      "topic_id" => topic.id,
      "user_id" => user.id,
      "body" => attrs["body"],
      "body_json" => attrs["body_json"],
      "post_number" => post_number,
      "parent_id" => attrs["parent_id"]
    }

    result =
      Repo.transaction(fn ->
        post =
          case %Post{} |> Post.changeset(post_attrs) |> Repo.insert() do
            {:ok, p} -> p
            {:error, changeset} -> Repo.rollback(changeset)
          end

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

        post
      end)

    # Side effects run AFTER the transaction commits, otherwise subscribers that
    # reload on the broadcast query the DB before the post is visible.
    case result do
      {:ok, post} ->
        ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "new_post", %{
          post_id: post.id,
          user_id: user.id
        })

        enqueue_embed(post)
        enqueue_mentions(post)
        # Auto-watch the topic for whoever replies (Discourse behaviour).
        Colloq.Subscriptions.watch_if_new(user.id, topic.id)
        notify_post_subscribers(post, topic, user)

        {:ok, post}

      error ->
        error
    end
    end
  end

  # Notify people about a new reply, respecting per-topic notification levels:
  # - "watching" users get every reply
  # - the reply target (parent comment author, or topic author) gets notified
  #   unless they muted the topic
  # Skips the poster and anyone who muted the topic.
  defp notify_post_subscribers(post, topic, actor) do
    watchers = Colloq.Subscriptions.topic_watcher_ids(topic.id)
    muters = Colloq.Subscriptions.topic_muter_ids(topic.id)
    target = reply_target_id(post, topic)

    recipients =
      [target | watchers]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == actor.id or MapSet.member?(muters, &1)))

    for recipient_id <- recipients do
      create_reply_notification(recipient_id, actor, topic, post)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reply_target_id(%Post{parent_id: parent_id}, _topic) when not is_nil(parent_id) do
    case Repo.get(Post, parent_id) do
      %Post{user_id: uid} -> uid
      _ -> nil
    end
  end

  defp reply_target_id(_post, topic), do: topic.user_id

  defp create_reply_notification(recipient_id, actor, topic, post) do
    Colloq.Notifications.create_notification(%{
      user_id: recipient_id,
      type: "reply",
      title: "#{actor.username} respondió en «#{topic.title}»",
      body: "",
      data: %{
        "topic_id" => topic.id,
        "post_id" => post.id,
        "actor_id" => actor.id,
        "actor_username" => actor.username
      }
    })
  end

  # Enqueue link-unfurling for a post's URLs (best-effort; ignored if Oban is down).
  defp enqueue_embed(%Post{} = post) do
    %{post_id: post.id}
    |> Colloq.Workers.EmbedWorker.new()
    |> Oban.insert()
  rescue
    _ -> :ok
  end

  # Enqueue @mention processing (notifications + bot triggers) for a post.
  defp enqueue_mentions(%Post{} = post) do
    %{post_id: post.id}
    |> Colloq.Workers.MentionTriggerWorker.new()
    |> Oban.insert()
  rescue
    _ -> :ok
  end

  @doc """
  Creates a nested reply to a specific post within a topic.

  Returns `{:error, :invalid_parent}` if the parent post does not belong to the topic.
  Otherwise delegates to `create_post/3`.
  """
  def create_reply(%Topic{} = topic, %Accounts.User{} = user, %Post{} = parent_post, attrs) do
    if parent_post.topic_id != topic.id do
      {:error, :invalid_parent}
    else
      attrs = Map.merge(attrs, %{"parent_id" => parent_post.id})
      create_post(topic, user, attrs)
    end
  end

  @doc """
  Updates a topic's editable fields (title, category, tags).

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def update_topic(%Topic{} = topic, attrs) do
    tag_names = attrs["tags"]

    result =
      topic
      |> Topic.changeset(Map.merge(attrs, %{"user_id" => topic.user_id}))
      |> Repo.update()

    case result do
      {:ok, updated} when is_list(tag_names) ->
        tags = Colloq.Tags.find_or_create_tags(tag_names)
        Colloq.Tags.set_topic_tags(updated, tags)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc """
  Closes a topic, preventing new posts.

  Returns `{:ok, topic}` or `{:error, changeset}`.
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
  Archives a topic (manual or via automation).

  Returns `{:ok, topic}` or `{:error, changeset}`.
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
  Sets match mode on a match thread.

  `mode` must be one of `"prematch"`, `"live"`, or `"fulltime"`.

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def set_match_mode(%Topic{} = topic, mode) when mode in ["prematch", "live", "fulltime"] do
    topic
    |> Ecto.Changeset.change(match_mode: mode)
    |> Repo.update()
  end

  # --- POSTS ---

  @doc """
  Gets a post by ID with user and topic preloaded.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_post!(id), do: Repo.get!(Post, id) |> Repo.preload([:user, :topic])

  @doc """
  Updates a post's content.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def update_post(%Post{} = post, attrs) do
    case post |> Post.changeset(attrs) |> Repo.update() do
      {:ok, updated} = ok ->
        # Re-unfurl links: an edit may have added or removed URLs.
        enqueue_embed(updated)
        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes (hides) a post by setting `deleted_at`.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def delete_post(%Post{} = post) do
    post
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  Increments the view count for a post (fire-and-forget).

  Returns `{count, nil}`.
  """
  def increment_post_view(%Post{} = post) do
    Post
    |> where(id: ^post.id)
    |> Repo.update_all(inc: [view_count: 1])
  end

  @doc """
  Increments a topic's view counter by one. Fire-and-forget.
  """
  def increment_topic_views(topic_id) do
    Topic
    |> where(id: ^topic_id)
    |> Repo.update_all(inc: [views_count: 1])
  end

  # --- CATEGORIES ---

  @doc """
  Lists all categories ordered by position.

  Returns `[%Category{}]`.
  """
  def list_categories do
    Category
    |> order_by(:position)
    |> Repo.all()
  end

  @doc """
  Gets a category by ID.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_category!(id), do: Repo.get!(Category, id)

  @doc """
  Creates a category. Admin only.

  Returns `{:ok, category}` or `{:error, changeset}`.
  """
  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a category. Admin only.

  Returns `{:ok, category}` or `{:error, changeset}`.
  """
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a category. Admin only.
  Returns {:error, :has_topics} if the category still has topics.
  """
  def delete_category(%Category{} = category) do
    topic_count = Repo.aggregate(from(t in Topic, where: t.category_id == ^category.id), :count)

    if topic_count > 0 do
      {:error, :has_topics}
    else
      Repo.delete(category)
    end
  end

  # --- SEARCH (ParadeDB BM25) ---

  @doc """
  Searches posts using ParadeDB BM25 full-text search.

  ## Options

    * `:limit` - max results (default 20)
    * `:offset` - pagination offset (default 0)

  Returns a list of maps with `:id`, `:body`, `:inserted_at`, `:topic_id`, and `:rank`.
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
  Searches topics using ParadeDB BM25 full-text search on titles.

  ## Options

    * `:limit` - max results (default 20)

  Returns a list of maps with `:id`, `:title`, `:slug`, `:inserted_at`, and `:rank`.
  Returns `[]` if pg_search is not available.
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

  # =========================================================================
  # Polls
  # =========================================================================

  alias Colloq.Forum.{Poll, PollOption, PollVote}

  @doc """
  Creates a poll with options for a post.

  Options is a list of strings. Returns {:ok, poll} or {:error, changeset}.
  """
  def create_poll(post, question, options, opts \\ []) do
    multiple = Keyword.get(opts, :multiple, false)

    Repo.transaction(fn ->
      poll =
        %Poll{}
        |> Poll.changeset(%{
          question: question,
          multiple: multiple,
          post_id: post.id
        })
        |> Repo.insert!()

      options
      |> Enum.with_index()
      |> Enum.each(fn {text, idx} ->
        %PollOption{}
        |> PollOption.changeset(%{
          text: text,
          position: idx,
          poll_id: poll.id
        })
        |> Repo.insert!()
      end)

      poll |> Repo.preload(:options)
    end)
  end

  @doc """
  Casts a vote for a poll option. One vote per user per poll (unless multiple).
  """
  def cast_vote(poll, option, user) do
    if poll.closed do
      {:error, :poll_closed}
    else
      if poll.multiple do
        cast_multiple_vote(poll, option, user)
      else
        cast_single_vote(poll, option, user)
      end
    end
  end

  defp cast_single_vote(poll, option, user) do
    case existing_vote_for_option(poll.id, option.id, user.id) do
      nil ->
        %PollVote{}
        |> PollVote.changeset(%{
          poll_id: poll.id,
          poll_option_id: option.id,
          user_id: user.id
        })
        |> Repo.insert()

      _existing ->
        {:error, :already_voted}
    end
  end

  defp cast_multiple_vote(poll, option, user) do
    case existing_vote_for_option(poll.id, option.id, user.id) do
      nil ->
        %PollVote{}
        |> PollVote.changeset(%{
          poll_id: poll.id,
          poll_option_id: option.id,
          user_id: user.id
        })
        |> Repo.insert()

      existing ->
        Repo.delete(existing)
        {:ok, :removed}
    end
  end

  defp existing_vote_for_option(poll_id, option_id, user_id) do
    from(v in PollVote,
      where: v.poll_id == ^poll_id and v.poll_option_id == ^option_id and v.user_id == ^user_id
    )
    |> Repo.one()
  end

  @doc """
  Returns poll results with vote counts per option.
  """
  def poll_results(poll) do
    poll = Repo.preload(poll, options: :votes)

    total_votes =
      poll.options
      |> Enum.map(&length(&1.votes))
      |> Enum.sum()

    options =
      poll.options
      |> Enum.sort_by(& &1.position)
      |> Enum.map(fn opt ->
        count = length(opt.votes)

        %{
          id: opt.id,
          text: opt.text,
          votes: count,
          percentage: if(total_votes > 0, do: round(count / total_votes * 100), else: 0)
        }
      end)

    %{poll: poll, options: options, total_votes: total_votes}
  end

  @doc """
  Gets the user's current vote(s) for a poll.
  """
  def user_poll_votes(poll_id, user_id) do
    from(v in PollVote,
      where: v.poll_id == ^poll_id and v.user_id == ^user_id
    )
    |> Repo.all()
  end

  @doc """
  Preloads poll with options and vote counts for a list of posts.
  """
  def preload_polls(post_ids) do
    polls =
      from(p in Poll,
        where: p.post_id in ^post_ids,
        preload: [:options, :votes]
      )
      |> Repo.all()

    Map.new(polls, &{&1.post_id, &1})
  end

  # =========================================================================
  # Voice Rooms
  # =========================================================================

  alias Colloq.Forum.VoiceRoom

  @doc """
  Lists all active voice rooms.

  Returns `[%VoiceRoom{}]` with `:topic` and `:created_by` preloaded.
  """
  def list_voice_rooms do
    VoiceRoom
    |> order_by(:name)
    |> preload([:topic, :created_by])
    |> Repo.all()
  end

  @doc """
  Gets a voice room by ID. Raises if not found.
  """
  def get_voice_room!(id), do: Repo.get!(VoiceRoom, id) |> Repo.preload([:topic, :created_by])

  @doc """
  Gets a voice room by slug. Returns `nil` if not found.
  """
  def get_voice_room_by_slug(slug) do
    Repo.get_by(VoiceRoom, slug: slug) |> Repo.preload([:topic, :created_by])
  end

  @doc """
  Creates a voice room.

  Returns `{:ok, voice_room}` or `{:error, changeset}`.
  """
  def create_voice_room(user, attrs) do
    %VoiceRoom{}
    |> VoiceRoom.changeset(Map.put(attrs, "created_by_id", user.id))
    |> Repo.insert()
  end

  @doc """
  Updates a voice room.

  Returns `{:ok, voice_room}` or `{:error, changeset}`.
  """
  def update_voice_room(%VoiceRoom{} = room, attrs) do
    room
    |> VoiceRoom.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a voice room.

  Returns `{:ok, voice_room}` or `{:error, changeset}`.
  """
  def delete_voice_room(%VoiceRoom{} = room) do
    Repo.delete(room)
  end

  @doc """
  Checks if a user meets the trust level requirement for a voice room.

  Returns `true` if the user's trust level is sufficient, `false` otherwise.
  """
  def can_join_voice_room?(%VoiceRoom{} = room, user) do
    user.trust_level >= room.trust_level_required
  end
end
