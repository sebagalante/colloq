defmodule ColloqWeb.UserLive.Profile do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Forum
  alias Colloq.Reactions
  alias Colloq.Badges

  @per_page 20

  @impl true
  def mount(%{"username" => username}, session, socket) do
    current_user = load_user(session)
    user = Accounts.get_user_by_username(username)

    profile_badges =
      if user, do: Badges.get_user_display_badges(user.id) |> Enum.map(& &1.badge), else: []

    blocked_by_me =
      if current_user && user && current_user.id != user.id do
        Accounts.blocked?(current_user.id, user.id)
      else
        false
      end

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:profile_user, user)
      |> assign(:profile_badges, profile_badges)
      |> assign(:posts, [])
      |> assign(:post_reactions, %{})
      |> assign(:page, 1)
      |> assign(:has_more_posts, false)
      |> assign(:blocked_by_me, blocked_by_me)
      |> assign(:can_message, current_user && user && current_user.id != user.id &&
        Colloq.Messaging.can_message?(current_user, user) == :ok)
      |> assign(:active_tab, "summary")
      |> assign(:stats, if(user, do: load_profile_stats(user), else: %{}))
      |> assign(:online, user && ColloqWeb.Presence.online?(user.id))
      |> assign_new(:page_title, fn ->
        "@#{user && user.username || username}"
      end)

    # Activity loads on the dead render too, not just once the socket connects.
    # Gating it on connected?/1 meant every profile first painted "No posts yet"
    # and only filled in after the websocket came up.
    socket =
      if user && !blocked_by_me do
        {posts, has_more} = list_recent_posts(user.id)

        socket
        |> assign(:posts, posts)
        |> assign(:post_reactions, load_reactions(posts))
        |> assign(:has_more_posts, has_more)
      else
        socket
      end

    socket =
      if user && connected?(socket) && !blocked_by_me do
        # Live presence updates for the online indicator.
        Phoenix.PubSub.subscribe(Colloq.PubSub, "online_users")
        assign(socket, :online, ColloqWeb.Presence.online?(user.id))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(%{event: "presence_diff"}, socket) do
    user = socket.assigns.profile_user
    {:noreply, assign(socket, :online, user && ColloqWeb.Presence.online?(user.id))}
  end

  @impl true
  def handle_event("set-tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("load-more-activity", _params, socket) do
    %{profile_user: user, page: page, posts: posts} = socket.assigns

    if user && socket.assigns.has_more_posts do
      next_page = page + 1
      {more, has_more} = list_recent_posts(user.id, next_page)
      all = posts ++ more

      {:noreply,
       socket
       |> assign(:posts, all)
       |> assign(:post_reactions, Map.merge(socket.assigns.post_reactions, load_reactions(more)))
       |> assign(:page, next_page)
       |> assign(:has_more_posts, has_more)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("message-user", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user

    cond do
      is_nil(actor) ->
        {:noreply, push_redirect(socket, to: "/login")}

      to_string(actor.id) == to_string(user_id) ->
        {:noreply, socket}

      true ->
        target = Accounts.get_user!(String.to_integer(user_id))

        case Colloq.Messaging.can_message?(actor, target) do
          :ok ->
            case Colloq.Messaging.find_or_create_conversation(actor.id, target.id) do
              {:ok, conversation} ->
                {:noreply, push_navigate(socket, to: ~p"/messages/#{conversation.id}")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, gettext("Could not start the conversation."))}
            end

          {:error, :opted_out} ->
            {:noreply, put_flash(socket, :error, gettext("This user isn't accepting messages."))}

          {:error, :blocked} ->
            {:noreply, put_flash(socket, :error, gettext("You can't message this user."))}
        end
    end
  end

  def handle_event("block-user", %{"user_id" => user_id} = params, socket) do
    actor = socket.assigns.current_user
    mode = if params["mode"] == "ignore", do: "ignore", else: "block"

    case Accounts.block_user(actor.id, String.to_integer(user_id), mode) do
      {:ok, _} ->
        msg =
          if mode == "ignore",
            do: gettext("User ignored. You won't see their posts."),
            else: gettext("User blocked. Neither of you will see each other's posts.")

        {:noreply,
         socket
         |> assign(:blocked_by_me, true)
         |> assign(:posts, [])
         |> assign(:post_reactions, %{})
         |> put_flash(:info, msg)}

      {:error, :cannot_block_staff} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You can't block staff. You can ignore them to hide their posts.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not block the user."))}
    end
  end

  def handle_event("unblock-user", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user

    case Accounts.unblock_user(actor.id, String.to_integer(user_id)) do
      {:ok, _} ->
        user = socket.assigns.profile_user
        # Unblocking reveals the profile for the first time — reset to page 1.
        {posts, has_more} = list_recent_posts(user.id)

        {:noreply,
         socket
         |> assign(:blocked_by_me, false)
         |> assign(:posts, posts)
         |> assign(:post_reactions, load_reactions(posts))
         |> assign(:page, 1)
         |> assign(:has_more_posts, has_more)
         |> put_flash(:info, "Usuario desbloqueado.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo desbloquear al usuario.")}
    end
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  # One page of activity, plus whether another page exists. Fetching
  # `per_page + 1` rows answers "is there more?" without a second COUNT over
  # the user's whole post history.
  defp list_recent_posts(user_id, page \\ 1) do
    import Ecto.Query

    offset = (page - 1) * @per_page

    rows =
      Colloq.Forum.Post
      |> where(user_id: ^user_id)
      |> where([p], is_nil(p.deleted_at))
      # System posts (goals, cards, match summaries) are authored by the bot
      # account, but exclude them anyway so a profile stays a record of things
      # the person actually wrote.
      |> where([p], p.is_system == false)
      |> order_by(desc: :inserted_at)
      |> offset(^offset)
      |> limit(^(@per_page + 1))
      |> preload(:topic)
      |> Colloq.Repo.all()

    {Enum.take(rows, @per_page), length(rows) > @per_page}
  end

  defp load_reactions(posts) do
    posts
    |> Enum.map(& &1.id)
    |> Reactions.reaction_counts_for()
  end

  # Aggregate stats shown in the profile header (Joined / Last Post / Views /
  # Trust Level / Cheers), computed from the user's posts.
  defp load_profile_stats(user) do
    import Ecto.Query
    alias Colloq.Forum.Post
    alias Colloq.Reactions.Reaction
    alias Colloq.Repo

    last_post_at =
      Repo.one(
        from p in Post,
          where: p.user_id == ^user.id and is_nil(p.deleted_at),
          order_by: [desc: p.inserted_at],
          limit: 1,
          select: p.inserted_at
      )

    total_views =
      Repo.one(from p in Post, where: p.user_id == ^user.id, select: coalesce(sum(p.view_count), 0))

    cheers =
      Repo.one(
        from r in Reaction,
          join: p in Post,
          on: p.id == r.post_id,
          where: p.user_id == ^user.id,
          select: count(r.id)
      )

    %{
      posts_count: user.posts_count || 0,
      last_post_at: last_post_at,
      total_views: total_views || 0,
      cheers: cheers || 0
    }
  end

  def trust_level_name(level) do
    case level do
      0 -> gettext("new")
      1 -> gettext("basic")
      2 -> gettext("member")
      3 -> gettext("regular")
      4 -> gettext("leader")
      _ -> gettext("new")
    end
  end

  def short_date(nil), do: "—"
  def short_date(dt), do: Calendar.strftime(dt, "%d %b %Y")

  # Coarse relative time ("3d", "2mon", "1y") for header stats.
  def relative_time(nil), do: "—"

  def relative_time(%NaiveDateTime{} = dt),
    do: relative_time(DateTime.from_naive!(dt, "Etc/UTC"))

  def relative_time(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      secs < 60 -> gettext("just now")
      secs < 3600 -> gettext("%{n}m", n: div(secs, 60))
      secs < 86_400 -> gettext("%{n}h", n: div(secs, 3600))
      secs < 2_592_000 -> gettext("%{n}d", n: div(secs, 86_400))
      secs < 31_536_000 -> gettext("%{n}mon", n: div(secs, 2_592_000))
      true -> gettext("%{n}y", n: div(secs, 31_536_000))
    end
  end

  # Strip the scheme (and any trailing slash) so websites read like the pic.
  def display_website(nil), do: ""

  def display_website(url) do
    url
    |> String.replace(~r{^https?://}, "")
    |> String.replace(~r{/$}, "")
  end

  def trust_level_badge_color(level) do
    case level do
      0 -> "gray"
      1 -> "blue"
      2 -> "green"
      3 -> "purple"
      4 -> "amber"
      _ -> "gray"
    end
  end

  def member_since(user) do
    Calendar.strftime(user.inserted_at, "%d/%m/%Y")
  end

  @doc """
  Plain-text excerpt of a post body for previews.

  Bodies are stored as untrusted HTML, so we strip all markup (rather than
  rendering it raw) and truncate to a short preview. Escaping is handled by
  the default HEEx `<%= %>` interpolation in the template.
  """
  def body_excerpt(nil, _length), do: ""

  def body_excerpt(body, length) when is_binary(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.slice(0, length)
  end
end
