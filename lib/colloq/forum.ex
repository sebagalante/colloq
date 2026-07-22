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
    tag_slug = Keyword.get(opts, :tag_slug)
    order = Keyword.get(opts, :order, :latest)
    blocked_ids = Keyword.get(opts, :blocked_ids, MapSet.new())
    blocked_list = MapSet.to_list(blocked_ids)
    muted_list = opts |> Keyword.get(:muted_topic_ids, MapSet.new()) |> MapSet.to_list()
    hidden_cats = Keyword.get(opts, :hidden_category_ids, [])

    Topic
    |> where([t], is_nil(t.deleted_at))
    |> then(fn q ->
      # Topics in a staff-only category never appear in a public listing.
      if hidden_cats == [], do: q, else: where(q, [t], t.category_id not in ^hidden_cats)
    end)
    |> filter_by_category(category_id)
    |> filter_by_tag(tag_slug)
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
    |> preload([:category, :user, :first_post, last_post: :user])
    |> Pagination.paginate(page: page, page_size: per_page)
  end

  @doc """
  Ids of the "hot" topics — those with the most (non-deleted) posts created in
  the last `window_hours` (default 48h), so the topic list can tag them with a
  🔥 badge. Views break ties. Returns a `MapSet` of the top `:limit` ids
  (default 5); a quiet window yields an empty set.

  Options: `:limit`, `:window_hours`, `:blocked_ids`, `:muted_topic_ids`.
  """
  def hot_topic_ids(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    window_hours = Keyword.get(opts, :window_hours, 48)
    since = DateTime.add(DateTime.utc_now(), -window_hours * 3600, :second)
    blocked_list = opts |> Keyword.get(:blocked_ids, MapSet.new()) |> MapSet.to_list()
    muted_list = opts |> Keyword.get(:muted_topic_ids, MapSet.new()) |> MapSet.to_list()
    hidden_cats = Keyword.get(opts, :hidden_category_ids, [])

    from(p in Post,
      join: t in Topic,
      on: t.id == p.topic_id,
      where:
        p.inserted_at >= ^since and is_nil(p.deleted_at) and t.archived == false and
          is_nil(t.deleted_at),
      group_by: [p.topic_id, t.views_count],
      order_by: [desc: count(p.id), desc: t.views_count, desc: max(p.inserted_at)],
      select: p.topic_id
    )
    |> then(fn q ->
      if blocked_list != [], do: where(q, [p, t], t.user_id not in ^blocked_list), else: q
    end)
    |> then(fn q ->
      if muted_list != [], do: where(q, [p, t], p.topic_id not in ^muted_list), else: q
    end)
    |> then(fn q ->
      if hidden_cats != [], do: where(q, [p, t], t.category_id not in ^hidden_cats), else: q
    end)
    |> limit(^limit)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Top participants for each topic id — the most active posters, up to `limit`
  each. Returns `%{topic_id => [%{id, username, display_name, avatar_url}]}`,
  ordered by post count desc. One grouped query for the ids plus one for the
  users, so it's a fixed two queries regardless of list size.
  """
  def topic_participants(topic_ids, limit \\ 5)
  def topic_participants([], _limit), do: %{}

  def topic_participants(topic_ids, limit) do
    counts =
      from(p in Post,
        where: p.topic_id in ^topic_ids and not is_nil(p.user_id),
        group_by: [p.topic_id, p.user_id],
        select: {p.topic_id, p.user_id, count(p.id)}
      )
      |> Repo.all()

    top_by_topic =
      counts
      |> Enum.group_by(fn {tid, _, _} -> tid end)
      |> Map.new(fn {tid, rows} ->
        uids =
          rows
          |> Enum.sort_by(fn {_, _, n} -> n end, :desc)
          |> Enum.take(limit)
          |> Enum.map(fn {_, uid, _} -> uid end)

        {tid, uids}
      end)

    user_ids = top_by_topic |> Map.values() |> List.flatten() |> Enum.uniq()

    users =
      from(u in Accounts.User,
        where: u.id in ^user_ids,
        select:
          {u.id,
           %{id: u.id, username: u.username, display_name: u.display_name, avatar_url: u.avatar_url}}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(top_by_topic, fn {tid, uids} ->
      {tid, uids |> Enum.map(&Map.get(users, &1)) |> Enum.reject(&is_nil/1)}
    end)
  end

  # Pinned topics always float to the top; then the chosen ordering.
  # :top / :views → most viewed, :replies → most posts, :latest → recent activity.
  defp order_topics(query, order) when order in [:top, :views],
    do: order_by(query, [t], desc: t.pinned, desc: t.views_count, desc: t.bumped_at)

  defp order_topics(query, :replies),
    do: order_by(query, [t], desc: t.pinned, desc: t.posts_count, desc: t.bumped_at)

  defp order_topics(query, _latest),
    do: order_by(query, [t], desc: t.pinned, desc: t.bumped_at)

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, category_id), do: where(query, category_id: ^category_id)

  defp filter_by_tag(query, nil), do: query

  defp filter_by_tag(query, slug) do
    from t in query,
      join: tt in "topic_tags",
      on: tt.topic_id == t.id,
      join: tag in "tags",
      on: tag.id == tt.tag_id,
      where: tag.slug == ^slug
  end

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
      |> preload([:category, :user, :deleted_by, :duplicate_of])
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

      # A re-post of a topic the same author just opened gets closed on the
      # spot, the way a duplicate reply gets hidden. The content is kept and
      # the thread stays readable — it just can't collect a parallel discussion.
      topic = close_if_duplicate(topic, user)

      # Set tags. New tags are only materialised for users allowed to create
      # them; below the threshold, only existing tags are applied.
      if tag_names != [] do
        tags =
          Colloq.Tags.find_or_create_tags(tag_names,
            create: Colloq.Tags.can_create?(user),
            limit: Colloq.Tags.tag_limit(user)
          )

        Colloq.Tags.set_topic_tags(topic, tags)
      end

      enqueue_embed(post)
      enqueue_spam_check(user, post)

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

  # How far back a re-post still counts as a duplicate. Long enough to catch a
  # double submit or a "did that post?" retry, short enough that reviving a
  # subject weeks later is a new conversation, not a duplicate.
  @duplicate_topic_window_hours 24

  # Closes `topic` when the same author already has an open topic with the same
  # title. Returns the topic (closed or untouched) so the caller can keep going.
  #
  # Follows Discourse's "signpost closure": the duplicate is closed *and* records
  # which topic it duplicates, so the banner can link back. Discourse's guidance
  # is that whatever else moderators do, the duplicate always points at the
  # original — otherwise a reader arriving from search hits a dead end with no
  # idea where the conversation actually is. The notification only reaches the
  # author; `duplicate_of_id` is what everyone else sees.
  defp close_if_duplicate(%Topic{} = topic, %Accounts.User{} = user) do
    case find_duplicate_topic(topic, user) do
      nil ->
        topic

      original ->
        {:ok, closed} =
          topic
          |> Ecto.Changeset.change(
            closed: true,
            closed_at: DateTime.utc_now(),
            closed_reason: "duplicate",
            duplicate_of_id: original.id
          )
          |> Repo.update()

        notify_duplicate_topic(user, closed, original)
        closed
    end
  end

  # Titles are compared as slugs, so case, accents and punctuation don't
  # decide it: "Fecha 1 — Liga" and "fecha 1 liga" are the same topic.
  defp find_duplicate_topic(%Topic{} = topic, %Accounts.User{} = user) do
    case Colloq.Slug.slugify(topic.title) do
      nil ->
        nil

      slug ->
        since =
          DateTime.utc_now()
          |> DateTime.add(-@duplicate_topic_window_hours * 3600, :second)

        Topic
        |> where([t], t.user_id == ^user.id and t.id != ^topic.id)
        |> where([t], is_nil(t.deleted_at))
        |> where([t], t.inserted_at >= ^since)
        # A topic closed for hitting the 50k post cap is *meant* to be
        # continued, so its sequel is a legitimate new thread, not a duplicate.
        |> where([t], is_nil(t.closed_reason) or t.closed_reason != "post_limit")
        |> order_by(desc: :inserted_at)
        |> limit(20)
        |> Repo.all()
        |> Enum.find(&(Colloq.Slug.slugify(&1.title) == slug))
    end
  end

  defp notify_duplicate_topic(user, closed, original) do
    Colloq.Notifications.create_notification(%{
      user_id: user.id,
      type: "system",
      title: "Tema cerrado por duplicado",
      body:
        "Ya tenías un tema abierto con el mismo título, así que este quedó cerrado. " <>
          "Seguí la conversación en «#{original.title}».",
      data: %{"topic_id" => original.id, "duplicate_of" => original.id, "closed_topic_id" => closed.id}
    })
  rescue
    _ -> :ok
  end

  @default_duplicate_post_window_mins 5

  @doc """
  How many minutes the same body is refused for. Configurable via the
  `duplicate_post_window_mins` site setting; defaults to
  #{@default_duplicate_post_window_mins}. Set to `0` to allow duplicates.

  Named after Discourse's `unique_posts_mins`, which does the same job.
  """
  def duplicate_post_window_mins do
    case Colloq.SiteSettings.get("duplicate_post_window_mins") do
      n when is_integer(n) and n >= 0 ->
        n

      # SiteSettings.put/3 stores as "string" unless told otherwise, and the
      # admin form submits text — so a value set through either arrives here as
      # a binary. Reading only integers silently ignored the setting.
      n when is_binary(n) ->
        case Integer.parse(n) do
          {parsed, _} when parsed >= 0 -> parsed
          _ -> @default_duplicate_post_window_mins
        end

      _ ->
        @default_duplicate_post_window_mins
    end
  end

  # Refuses a post identical to one the same author made moments ago, the way
  # Discourse's `unique_posts_mins` does.
  #
  # This used to be a *spam* rule: the post was created, then the async detector
  # hid it, flagged it and told the author they'd been caught spamming — with no
  # time limit at all, so the same text weeks apart still counted. A double
  # submit is an accident, and the honest response is to refuse it up front and
  # say so, not to accept it and quietly remove it a minute later.
  #
  # System posts and bots are exempt: a bot answering the same question twice is
  # doing its job.
  defp check_not_duplicate(%Accounts.User{flair: "BOT"}, _attrs), do: :ok

  defp check_not_duplicate(%Accounts.User{} = user, attrs) do
    body = attrs["body"] || attrs[:body]
    window = duplicate_post_window_mins()

    cond do
      attrs["is_system"] || attrs[:is_system] -> :ok
      window <= 0 -> :ok
      not is_binary(body) -> :ok
      blank_body?(body) -> :ok
      recent_identical_post?(user.id, body, window) -> {:error, :duplicate_post}
      true -> :ok
    end
  end

  # Compared on the visible text, not the raw HTML: retyping the same sentence
  # can produce different Tiptap markup, and an empty paragraph shouldn't count.
  defp recent_identical_post?(user_id, body, window_mins) do
    since = DateTime.add(DateTime.utc_now(), -window_mins * 60, :second)
    normalized = normalize_body(body)

    Post
    |> where([p], p.user_id == ^user_id and p.inserted_at >= ^since)
    |> where([p], is_nil(p.deleted_at))
    |> order_by(desc: :inserted_at)
    |> limit(20)
    |> select([p], p.body)
    |> Repo.all()
    |> Enum.any?(&(normalize_body(&1) == normalized))
  end

  defp normalize_body(body) do
    body
    |> to_string()
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp blank_body?(body), do: normalize_body(body) == ""

  # Blocks banned/suspended/silenced users from creating topics or posts.
  # Bot output — ResultaBot's goal and card cards, standings, digests — is a
  # broadcast, not a conversation opener: threading replies under a goal alert
  # splits the match chat into dead-end branches. The UI already hides Reply on
  # system posts, but that is a hidden button, not a rule; a crafted event would
  # still thread underneath. Enforce it here, where posts are actually created.
  defp check_parent_repliable(attrs) do
    case attrs["parent_id"] || attrs[:parent_id] do
      nil ->
        :ok

      parent_id ->
        case Repo.get(Post, parent_id) do
          %Post{is_system: true} -> {:error, :cannot_reply_to_system_post}
          _ -> :ok
        end
    end
  end

  defp check_can_post(%Accounts.User{} = user) do
    cond do
      user.banned -> {:error, :banned}
      Accounts.User.suspended?(user) -> {:error, :suspended}
      Accounts.User.silenced?(user) -> {:error, :silenced}
      true -> :ok
    end
  end

  # Closed, archived, and announcement (staff_only) topics reject replies from
  # regular users. Staff (those who can edit topics) may always reply.
  defp check_topic_open(%Topic{} = topic, %Accounts.User{} = user) do
    cond do
      Colloq.Permissions.can?(user, :edit_topics) -> :ok
      topic.archived -> {:error, :topic_closed}
      topic.closed -> {:error, :topic_closed}
      topic.staff_only -> {:error, :topic_staff_only}
      true -> :ok
    end
  end

  @doc """
  Whether `user` may reply to `topic`, accounting for closed/archived/announcement
  state. Staff (with `:edit_topics`) can always reply.
  """
  def can_reply?(%Topic{} = topic, %Accounts.User{} = user) do
    check_topic_open(topic, user) == :ok
  end

  def can_reply?(_topic, _user), do: false

  @doc """
  Creates a reply (post) in a topic.

  Auto-closes the topic at 50,000 posts. Broadcasts a `"new_post"` event
  to the topic channel.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def create_post(%Topic{} = topic, %Accounts.User{} = user, attrs) do
    with :ok <- check_can_post(user),
         :ok <- check_topic_open(topic, user),
         :ok <- check_parent_repliable(attrs),
         :ok <- check_not_duplicate(user, attrs) do
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
      "parent_id" => attrs["parent_id"],
      # System-post fields (bot alerts, standings, …). Absent/false for normal
      # replies; passed through so callers can create system posts here.
      "is_system" => attrs["is_system"] || false,
      "system_type" => attrs["system_type"],
      "event_data" => attrs["event_data"]
    }

    result =
      Repo.transaction(fn ->
        post =
          case %Post{} |> Post.changeset(post_attrs) |> Repo.insert() do
            {:ok, p} -> p
            {:error, changeset} -> Repo.rollback(changeset)
          end

        # Update topic bump.
        #
        # posts_count is recounted, not set to post_number. post_number is a
        # high-water mark that only ever climbs, so once a post was deleted the
        # count permanently overstated — a topic with one surviving post could
        # read "8". Recounting here also self-heals any existing drift the next
        # time someone replies.
        topic
        |> Ecto.Changeset.change(
          posts_count: live_posts_count(topic.id),
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

        # Feeds the topic-list "new or updated topics" banner — a reply bumps
        # the topic, so the list is now stale for anyone viewing it.
        ColloqWeb.Endpoint.broadcast("forum:topic_list", "topic_bumped", %{
          topic_id: topic.id,
          category_id: topic.category_id
        })

        enqueue_embed(post)
        enqueue_mentions(post)
        enqueue_sofascore_command(post)
        enqueue_dolar_command(post)
        enqueue_clima_command(post)
        enqueue_resultabot_command(post)
        enqueue_f1_command(post)
        enqueue_ca_command(post)
        enqueue_spam_check(user, post)
        # Replying *tracks* the topic; it does not subscribe you to every
        # future reply. This used to call watch_if_new/2 — labelled "Discourse
        # behaviour", which it isn't: Discourse's
        # `default_other_notification_level_when_replying` defaults to Tracking.
        # Watching is reserved for the person who opened the topic, and for
        # anyone who picks it deliberately.
        Colloq.Subscriptions.track_if_new(user.id, topic.id)
        notify_post_subscribers(post, topic, user)

        {:ok, post}

      error ->
        error
    end
    end
  end

  # Notify people about a new reply, respecting per-topic notification levels:
  # - "watching" users get every reply
  # - whoever is being replied to directly gets notified at any level except
  #   "muted"
  # Skips the poster and anyone who muted the topic.
  defp notify_post_subscribers(post, topic, actor) do
    watchers = Colloq.Subscriptions.topic_watcher_ids(topic.id)
    muters = Colloq.Subscriptions.topic_muter_ids(topic.id)
    target = reply_target_id(post)

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

  # Only a reply to a *specific comment* counts as "replying to you".
  #
  # This used to fall back to `topic.user_id` for top-level replies, which meant
  # the topic author was notified of every reply in their topic no matter what
  # notification level they had chosen — setting "tracking" or "normal" changed
  # nothing for them, because this bypassed the level entirely. A top-level
  # reply addresses the topic, not a person, so it now reaches watchers only;
  # an author who wants every reply is already covered by "watching", which is
  # what `watch_if_new/2` gives them by default.
  defp reply_target_id(%Post{parent_id: parent_id}) when not is_nil(parent_id) do
    case Repo.get(Post, parent_id) do
      %Post{user_id: uid} -> uid
      _ -> nil
    end
  end

  defp reply_target_id(_post), do: nil

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

  # Screen posts from not-yet-trusted users (TL0/TL1) for spam, asynchronously.
  # Trusted users skip it entirely. The worker also re-checks trust level, so
  # this is just an early filter to avoid enqueueing needless jobs.
  # System posts are never screened. Bots answer the same question with the same
  # words by design — ask "/sofascore fecha liga" twice and the two replies are
  # byte-identical — which the duplicate-content rule reads as spam. sofascorebot
  # sits at TL1, so it was screened like a new user and hid its own answers.
  defp enqueue_spam_check(_user, %Post{is_system: true}), do: :ok

  defp enqueue_spam_check(%Accounts.User{flair: "BOT"}, %Post{}), do: :ok

  defp enqueue_spam_check(%Accounts.User{trust_level: tl}, %Post{} = post) when tl in [0, 1] do
    %{post_id: post.id}
    |> Colloq.Workers.SpamDetectorWorker.new()
    |> Oban.insert()
  rescue
    _ -> :ok
  end

  defp enqueue_spam_check(_user, _post), do: :ok

  # Enqueue @mention processing (notifications + bot triggers) for a post.
  defp enqueue_mentions(%Post{} = post) do
    %{post_id: post.id}
    |> Colloq.Workers.MentionTriggerWorker.new()
    |> Oban.insert()
  rescue
    _ -> :ok
  end

  # If a post is a "/sofascore ..." command, enqueue the command worker to
  # answer it in-topic. Only enqueued when the body starts with the trigger,
  # so ordinary posts pay no cost.
  defp enqueue_sofascore_command(%Post{body: body} = post) when is_binary(body) do
    # Posts are stored as HTML (Tiptap), so strip tags before checking for the
    # command prefix — otherwise the body starts with "<p>", not "/sofascore".
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.downcase()

    if String.starts_with?(plain, "/sofascore") do
      %{post_id: post.id}
      |> Colloq.Workers.SofascoreCommandWorker.new()
      |> Oban.insert()
    end
  rescue
    _ -> :ok
  end

  defp enqueue_sofascore_command(_), do: :ok

  # `/resultabot` starts live match coverage. The worker does the authorisation
  # and match-thread checks — this only decides whether to look at the post at
  # all, so ordinary posts pay nothing.
  defp enqueue_resultabot_command(%Post{body: body} = post) when is_binary(body) do
    if Colloq.Workers.ResultabotCommandWorker.command?(body) do
      %{post_id: post.id}
      |> Colloq.Workers.ResultabotCommandWorker.new()
      |> Oban.insert()
    end
  rescue
    _ -> :ok
  end

  defp enqueue_resultabot_command(_), do: :ok

  defp enqueue_dolar_command(%Post{body: body} = post) when is_binary(body) do
    # Same as above: strip the Tiptap HTML before matching the prefix.
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.downcase()

    if String.starts_with?(plain, "/dolar") do
      %{post_id: post.id}
      |> Colloq.Workers.DolarCommandWorker.new()
      |> Oban.insert()
    end
  rescue
    _ -> :ok
  end

  defp enqueue_dolar_command(_), do: :ok

  defp enqueue_clima_command(%Post{body: body} = post) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.downcase()

    if String.starts_with?(plain, "/clima") do
      %{post_id: post.id}
      |> Colloq.Workers.ClimaCommandWorker.new()
      |> Oban.insert()
    end
  rescue
    _ -> :ok
  end

  defp enqueue_clima_command(_), do: :ok

  # "/f1 …" — FangioBot answers with F1 standings, results and calendar.
  defp enqueue_f1_command(%Post{body: body} = post) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.downcase()

    if String.starts_with?(plain, "/f1") do
      %{post_id: post.id}
      |> Colloq.Workers.F1CommandWorker.new()
      |> Oban.insert()
    end
  rescue
    _ -> :ok
  end

  defp enqueue_f1_command(_), do: :ok

  # "/ca …" — CAbot answers with Copa Argentina fixtures and results.
  defp enqueue_ca_command(%Post{body: body} = post) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.downcase()

    # Word boundary, not a bare prefix: "/calendario" starts with "/ca" but is
    # not this command, and would otherwise queue a job that does nothing.
    if Regex.match?(~r/^\/ca\b/i, plain) do
      %{post_id: post.id}
      |> Colloq.Workers.CaCommandWorker.new()
      |> Oban.insert()
    end
  rescue
    _ -> :ok
  end

  defp enqueue_ca_command(_), do: :ok

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
  def update_topic(%Topic{} = topic, attrs, opts \\ []) do
    tag_names = attrs["tags"]
    can_create = Keyword.get(opts, :can_create, true)
    tag_limit = Keyword.get(opts, :tag_limit, :unlimited)

    result =
      topic
      |> Topic.changeset(Map.merge(attrs, %{"user_id" => topic.user_id}))
      |> Repo.update()

    case result do
      {:ok, updated} when is_list(tag_names) ->
        tags = Colloq.Tags.find_or_create_tags(tag_names, create: can_create, limit: tag_limit)
        Colloq.Tags.set_topic_tags(updated, tags)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc """
  Pins or unpins a topic (toggles). Pinned topics sort to the top of lists.

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def toggle_pin(%Topic{} = topic) do
    pinned = !topic.pinned

    topic
    |> Ecto.Changeset.change(
      pinned: pinned,
      pinned_at: if(pinned, do: DateTime.utc_now(), else: nil)
    )
    |> Repo.update()
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
  Stores a freshly generated AI summary on the topic, recording the model,
  timestamp, and the post count at generation (used to detect staleness).

  `attrs` is `%{summary, model, generated_at, post_number}`.
  """
  def put_topic_summary(%Topic{} = topic, attrs) do
    topic
    |> Ecto.Changeset.change(
      summary: attrs.summary,
      summary_model: attrs.model,
      summary_generated_at: attrs.generated_at,
      summary_post_number: attrs.post_number
    )
    |> Repo.update()
  end

  @doc """
  Reopens a closed topic, allowing new posts again.

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def reopen_topic(%Topic{} = topic) do
    topic
    |> Ecto.Changeset.change(
      closed: false,
      closed_at: nil,
      closed_reason: nil
    )
    |> Repo.update()
  end

  @doc """
  Toggles announcement (staff-only) mode: when enabled, only staff can reply
  while everyone can read.

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def set_staff_only(%Topic{} = topic, staff_only) when is_boolean(staff_only) do
    topic
    |> Ecto.Changeset.change(staff_only: staff_only)
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
  Soft-deletes a topic (Discourse-style): records `deleted_at` and who did it.

  The topic and its posts stay in the database, are hidden from regular users
  (excluded from every listing and 404 on direct visit), and remain visible to
  staff with a tombstone so they can `restore_topic/1`.

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def delete_topic(%Topic{} = topic, %Accounts.User{} = actor) do
    topic
    |> Ecto.Changeset.change(
      deleted_at: DateTime.utc_now(),
      deleted_by_id: actor.id
    )
    |> Repo.update()
  end

  @doc """
  Lists soft-deleted topics for the staff moderation queue, most recently
  deleted first, with `:user`, `:category`, and `:deleted_by` preloaded.
  """
  def list_deleted_topics do
    from(t in Topic,
      where: not is_nil(t.deleted_at),
      order_by: [desc: t.deleted_at],
      preload: [:user, :category, :deleted_by]
    )
    |> Repo.all()
  end

  @doc """
  Restores a soft-deleted topic, clearing `deleted_at`/`deleted_by_id`.

  Returns `{:ok, topic}` or `{:error, changeset}`.
  """
  def restore_topic(%Topic{} = topic) do
    topic
    |> Ecto.Changeset.change(deleted_at: nil, deleted_by_id: nil)
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
  # Edits inside this window of the original post don't get marked. Fixing a
  # typo ten seconds after posting shouldn't brand the post as edited forever —
  # the same grace period Discourse applies before it records a revision.
  @edit_grace_period_seconds 300

  def update_post(%Post{} = post, attrs) do
    post
    |> Post.changeset(attrs)
    |> stamp_edited_at(post)
    |> Repo.update()
    |> case do
      {:ok, updated} = ok ->
        # Re-unfurl links: an edit may have added or removed URLs.
        enqueue_embed(updated)
        ok

      error ->
        error
    end
  end

  # Only a genuine change to the body counts. Opening the editor and saving
  # without touching anything leaves no mark, and neither does a change that
  # only affects other fields.
  defp stamp_edited_at(changeset, %Post{} = post) do
    now = DateTime.utc_now()
    within_grace? = DateTime.diff(now, post.inserted_at) <= @edit_grace_period_seconds

    if Ecto.Changeset.changed?(changeset, :body) and not within_grace? do
      Ecto.Changeset.put_change(changeset, :edited_at, now)
    else
      changeset
    end
  end

  @doc """
  Soft-deletes a post at the author's own request (sets `deleted_at`, records
  who removed it, and leaves `hidden: false` so it stays out of the moderation
  queue). For a moderator/system removal use `Moderation.hide_post/2` instead.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def delete_post(%Post{} = post, actor \\ nil) do
    changes = [deleted_at: DateTime.utc_now(), hidden: false, deleted_by_id: actor && actor.id]

    case post |> Ecto.Changeset.change(changes) |> Repo.update() do
      {:ok, _updated} = ok ->
        # A soft delete never used to touch either counter, so the topic's
        # posts_count and the author's kept counting posts nobody can see.
        resync_post_counts(post)

        # Deleting the newest post left bumped_at (and last_post_id) pointing at
        # a post nobody can see, so the topic kept showing "now" in the list.
        # Roll both back to the newest surviving post.
        resync_topic_last_post(post.topic_id)

        # Push the removal to everyone viewing the topic so it disappears in
        # real time instead of lingering until their next reload.
        ColloqWeb.Endpoint.broadcast("forum:topic:#{post.topic_id}", "post_deleted", %{
          post_id: post.id
        })

        # The delete changed the topic's "last activity" and its order in the
        # list, so tell the index the same way a new reply does — otherwise the
        # front page shows the stale time until a manual refresh.
        if topic = Repo.get(Topic, post.topic_id) do
          ColloqWeb.Endpoint.broadcast("forum:topic_list", "topic_bumped", %{
            topic_id: topic.id,
            category_id: topic.category_id
          })
        end

        ok

      error ->
        error
    end
  end

  # Posts still visible in a topic. The counters track what readers can
  # actually see, so soft-deleted rows never count.
  defp live_posts_count(topic_id) do
    Repo.one(
      from p in Post,
        where: p.topic_id == ^topic_id and is_nil(p.deleted_at),
        select: count(p.id)
    ) || 0
  end

  @doc """
  Recompute the topic and author post counts a post contributes to.

  Public because moderation hides/restores posts by setting `deleted_at`
  directly, outside `delete_post/2`, and must resync the same way. Recounting
  rather than incrementing means a double-hide or an already-drifted row can't
  push a counter negative.
  """
  def resync_post_counts(%Post{topic_id: topic_id, user_id: user_id}) do
    from(t in Topic, where: t.id == ^topic_id)
    |> Repo.update_all(set: [posts_count: live_posts_count(topic_id)])

    if user_id do
      live =
        Repo.one(
          from p in Post,
            where: p.user_id == ^user_id and is_nil(p.deleted_at),
            select: count(p.id)
        ) || 0

      from(u in Colloq.Accounts.User, where: u.id == ^user_id)
      |> Repo.update_all(set: [posts_count: live])
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Recompute a topic's `last_post_id` and `bumped_at` from its newest surviving
  post, so deleting/hiding the last reply rolls "last activity" back instead of
  freezing on the removed post.

  Idempotent: if the newest post still survives, both values are simply set to
  what they already were. If nothing survives, `bumped_at` falls back to the
  topic's creation time and `last_post_id` to nil.
  """
  def resync_topic_last_post(topic_id) do
    last =
      Repo.one(
        from p in Post,
          where: p.topic_id == ^topic_id and is_nil(p.deleted_at),
          order_by: [desc: p.post_number],
          limit: 1,
          select: %{id: p.id, inserted_at: p.inserted_at}
      )

    topic = Repo.get(Topic, topic_id)

    if topic do
      {last_post_id, bumped_at} =
        case last do
          nil -> {nil, topic.inserted_at}
          %{id: id, inserted_at: at} -> {id, at}
        end

      topic
      |> Ecto.Changeset.change(last_post_id: last_post_id, bumped_at: bumped_at)
      |> Repo.update()
    end

    :ok
  rescue
    _ -> :ok
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
  @doc """
  Whether `user` may see restricted ("staff only") categories and their topics.

  One predicate, used by every listing, so "restricted" can't mean different
  things in the sidebar, the topic list and search.
  """
  def can_view_restricted?(user),
    do: Colloq.Permissions.can?(user, :view_restricted_categories)

  @doc """
  Ids of categories the given user must not see. Empty for staff.

  Returned as a list (not a query) because it is small, changes rarely, and
  every caller needs it as a `not in ^ids` clause.
  """
  def hidden_category_ids(user) do
    if can_view_restricted?(user) do
      []
    else
      Category
      |> where([c], c.read_restricted == true)
      |> select([c], c.id)
      |> Repo.all()
    end
  end

  @doc """
  Categories visible to `user` — restricted ones are dropped for non-staff.

  `list_categories/0` (no user) still returns everything, for the admin screens
  that must show what exists.
  """
  def list_categories(user) do
    hidden = hidden_category_ids(user)

    Category
    |> then(fn q -> if hidden == [], do: q, else: where(q, [c], c.id not in ^hidden) end)
    |> order_by([c], asc: c.position, asc: c.name)
    |> Repo.all()
  end

  def list_categories do
    Category
    # Name breaks ties: several categories share position 0, and ordering by
    # position alone let Postgres return them in whatever order it liked, so
    # the sidebar could reshuffle between requests.
    |> order_by([c], asc: c.position, asc: c.name)
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
    topic_count =
      Repo.aggregate(
        from(t in Topic, where: t.category_id == ^category.id and is_nil(t.deleted_at)),
        :count
      )

    if topic_count > 0 do
      {:error, :has_topics}
    else
      Repo.delete(category)
    end
  end

  # --- SEARCH (basic Postgres ILIKE — no extension required) ---
  #
  # Multi-word queries match rows that contain EVERY word (AND). Results are
  # ordered by recency (there's no relevance ranking — that's the tradeoff for
  # staying on stock Postgres). Good enough for a "basic search"; swap in
  # Postgres full-text (`to_tsvector`/`websearch_to_tsquery` + a GIN index)
  # later if ranking/scale demands it.

  @doc """
  Searches non-archived topics by title. Returns `Topic` structs (with
  `:category` and `:user` preloaded), most recent first. Blank query → `[]`.
  """
  def search_topics(query_string, opts \\ []) do
    case search_terms(query_string) do
      [] ->
        []

      terms ->
        limit = Keyword.get(opts, :limit, 20)
        hidden_cats = Keyword.get(opts, :hidden_category_ids, [])

        base =
          from(t in Topic,
            where: t.archived == false and is_nil(t.deleted_at),
            order_by: [desc: t.bumped_at],
            limit: ^limit,
            preload: [:category, :user]
          )

        terms
        |> Enum.reduce(base, fn term, q ->
          from(t in q, where: ilike(t.title, ^like_pattern(term)))
        end)
        |> then(fn q ->
          if hidden_cats == [], do: q, else: from(t in q, where: t.category_id not in ^hidden_cats)
        end)
        |> Repo.all()
    end
  end

  @doc """
  Searches visible posts by body text. Returns `Post` structs (with `:user` and
  `:topic` preloaded), most recent first. Blank query → `[]`.
  """
  def search_posts(query_string, opts \\ []) do
    case search_terms(query_string) do
      [] ->
        []

      terms ->
        limit = Keyword.get(opts, :limit, 20)
        hidden_cats = Keyword.get(opts, :hidden_category_ids, [])

        base =
          from(p in Post,
            where: is_nil(p.deleted_at) and p.is_system == false,
            order_by: [desc: p.inserted_at],
            limit: ^limit,
            preload: [:user, topic: :category]
          )

        terms
        |> Enum.reduce(base, fn term, q ->
          from(p in q, where: ilike(p.body, ^like_pattern(term)))
        end)
        |> then(fn q ->
          # Post bodies leak their topic just as surely as titles do, so the
          # same category filter has to apply here — via a join, since the
          # category lives on the topic.
          if hidden_cats == [] do
            q
          else
            from(p in q, join: t in Topic, on: t.id == p.topic_id, where: t.category_id not in ^hidden_cats)
          end
        end)
        |> Repo.all()
    end
  end

  # Split a query into search words, capped so a pathological input can't
  # build an enormous query.
  defp search_terms(query_string) do
    (query_string || "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(6)
  end

  # Escape LIKE wildcards so user input is matched literally, then wrap for a
  # contains-match.
  defp like_pattern(term) do
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
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
    anonymous = Keyword.get(opts, :anonymous, false)

    Repo.transaction(fn ->
      poll =
        %Poll{}
        |> Poll.changeset(%{
          question: question,
          multiple: multiple,
          anonymous: anonymous,
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
    poll = Repo.preload(poll, options: [votes: :user])

    total_votes =
      poll.options
      |> Enum.map(&length(&1.votes))
      |> Enum.sum()

    options =
      poll.options
      |> Enum.sort_by(& &1.position)
      |> Enum.map(fn opt ->
        count = length(opt.votes)

        voters =
          opt.votes
          |> Enum.map(& &1.user)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(
            &%{
              id: &1.id,
              username: &1.username,
              display_name: &1.display_name,
              avatar_url: &1.avatar_url
            }
          )

        %{
          id: opt.id,
          text: opt.text,
          votes: count,
          percentage: if(total_votes > 0, do: round(count / total_votes * 100), else: 0),
          voters: voters
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

  # --- LINEUPS ("the XI I'd play", attached to a post) ---

  alias Colloq.Forum.PostLineup

  @doc """
  Attaches a starting XI to a post. `players` is the frozen snapshot of the
  chosen XI (a list of maps), so the post keeps showing what its author picked
  even after the squad changes.

  Returns `{:ok, lineup}` or `{:error, changeset}`.
  """
  def create_lineup(%Post{} = post, attrs) do
    %PostLineup{}
    |> PostLineup.changeset(Map.put(attrs, :post_id, post.id))
    |> Repo.insert()
  end

  @doc "Lineups for the given post ids, keyed by `post_id`."
  def preload_lineups(post_ids) do
    from(l in PostLineup, where: l.post_id in ^post_ids)
    |> Repo.all()
    |> Map.new(&{&1.post_id, &1})
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
