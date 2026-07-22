defmodule ColloqWeb.ForumLive.Topic do
  @moduledoc """
  LiveView for displaying a forum topic with its threaded post tree.

  Features:
  - Threaded replies (nested posts) with real-time updates via PubSub
  - Emoji reactions on posts
  - Inline polls attached to posts (create, vote, view results)
  - Post bookmarks and flagging/reporting
  - AI-generated topic summaries (via Oban background job + Cachex)
  - Typing indicators showing who is composing a reply
  - User trust-level badges and custom display badges
  - Share links (copy, WhatsApp, Twitter, Telegram)
  - Tiptap HTML body rendering with XSS sanitization
  """
  use ColloqWeb, :live_view

  require Logger

  alias Colloq.Forum
  alias Colloq.Repo
  alias Colloq.Accounts
  alias Colloq.Reactions
  alias Colloq.Reads
  alias Colloq.Tags

  @typing_timeout 5_000

  # Longest quote (whole-post or selected) that gets inserted into a composer.
  @quote_limit 4_000

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    current_user = load_user(session)
    blocked_ids = if current_user, do: Accounts.hidden_user_ids(current_user.id), else: MapSet.new()
    topic = Forum.get_topic!(id, blocked_ids)
    can_delete_topic = current_user && Colloq.Permissions.can?(current_user, :delete_topics)

    # A topic in a staff-only category 404s for everyone else, so a shared or
    # guessed /t/:id link leaks nothing. Filtering the listings isn't enough on
    # its own — direct access is the case that actually matters.
    if topic.category && topic.category.read_restricted &&
         !Forum.can_view_restricted?(current_user) do
      raise Ecto.NoResultsError, queryable: Colloq.Forum.Topic
    end

    # A soft-deleted topic 404s for everyone except staff, who see it with a
    # tombstone so they can recover it.
    if topic.deleted_at && !can_delete_topic do
      raise Ecto.NoResultsError, queryable: Colloq.Forum.Topic
    end

    # Set up all assigns with sensible defaults.
    # UI-only state (form visibility, replying_to, poll form) is initialised
    # to empty/false so the template renders cleanly on first paint.
    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:topic, topic)
      |> assign(:can_delete_topic, can_delete_topic)
      |> assign(:posts, topic.posts)
      # Reply ordering: :chrono (posting order) or :top (most reactions first)
      |> assign(:sort, :chrono)
      # Emoji reaction counts per post id, e.g. %{123 => %{"👍" => 2}}
      |> assign(:reaction_data, %{})
      # Current user's reactions per post id, e.g. %{123 => ["👍"]}
      |> assign(:user_reactions, %{})
      # List of {user_id, username} tuples for the typing indicator bar
      |> assign(:typing_users, [])
      # Top-level reply composer state
      |> assign(:reply_body, "")
      |> assign(:replying_to, nil)
      |> assign(:nested_reply_body, "")
      |> assign(:editing_post, nil)
      |> assign(:editing_body, "")
      # Topic (title/category) edit state
      |> assign(:editing_topic, false)
      |> assign(:edit_title, topic.title)
      |> assign(:edit_category_id, topic.category_id)
      |> assign(:edit_tags, "")
      # Match-thread editor (staff only; fixtures loaded lazily on edit)
      |> assign(:can_manage_match, Colloq.Permissions.can?(current_user, :start_match_bot))
      |> assign(:match_fixtures, [])
      # Match mode flag inherited from the topic (e.g. live-match vs static)
      |> assign(:match_mode, topic.match_mode)
      # Score banner data for match threads (nil everywhere else)
      |> assign_match_banner(topic)
      # AI-generated summary (persisted on the topic; loaded below)
      |> assign(:summary, nil)
      |> assign(:summary_at, nil)
      |> assign(:summary_model, nil)
      |> assign(:summary_post_number, nil)
      |> assign(:summary_loading, false)
      |> assign(:summary_unavailable, false)
      # A stored summary is loaded on mount, but the panel only opens when the
      # reader actually asks for it.
      |> assign(:show_summary, false)
      # Inline poll creation form state
      |> assign(:show_poll_form, false)
      |> assign(:poll_question, "")
      |> assign(:poll_options, ["", ""])
      |> assign(:poll_anonymous, false)
      # "The XI I'd play" composer — loaded lazily when the form is opened
      |> assign(:show_lineup_form, false)
      |> assign(:lineup_teams, [])
      |> assign(:lineup_team_id, nil)
      |> assign(:lineup_formation, "4-3-1-2")
      |> assign(:lineup_colors, Colloq.Sofascore.team_colors(nil))
      |> assign(:lineup_slots, [])
      |> assign(:lineup_squad, [])
      # Lineups attached to the posts on screen, keyed by post_id
      |> assign(:lineup_data, %{})
      # Target of the "warn author" dialog, or nil when closed
      |> assign(:warning_target, nil)
      # Pre-computed poll results and the current user's votes
      |> assign(:poll_data, %{})
      |> assign(:user_poll_votes, %{})
      # Set of post ids the current user has bookmarked
      |> assign(:bookmarked_posts, %{})
      # Whether the current user has bookmarked this topic
      |> assign(:topic_bookmarked, current_user && Colloq.Bookmarks.topic_bookmarked?(current_user.id, topic.id))
      # Per-topic notification level (watching/tracking/normal/muted)
      |> assign(:notification_level, Colloq.Subscriptions.get_level(current_user && current_user.id, topic.id))
      # Post id whose flag/reason picker is currently visible (nil = hidden)
      |> assign(:show_flag_for, nil)
      # Pre-loaded display badges per user id
      |> assign(:user_badges, %{})
      # Tags on this topic
      |> assign(:topic_tags, Tags.get_topic_tags(topic.id))
      # Blocked user IDs for filtering posts
      |> assign(:blocked_user_ids, blocked_ids)
      # Where to land on open: "bottom" (newest post, via the activity-time link)
      # or "top" (first post, via the title link / default).
      |> assign(:scroll_to, if(params["to"] == "latest", do: "bottom", else: "top"))
      # "Where you left off". Computed read-only here (in BOTH the static and the
      # connected render) so the divider + pill are in the initial HTML — no
      # pop-in / layout shift when the socket connects. The actual "mark as read"
      # write happens once, on connect, further down. Nothing auto-scrolls.
      #   first_unread_id — post that gets the "New replies" divider
      #   unread_count    — new posts since last visit, shown on the jump pill
      |> assign_unread(topic, current_user, params["to"] == "latest")
      |> assign_new(:page_title, fn -> topic.title end)

    # Only subscribe to PubSub and load heavy data when the client is
    # actually connected (skip during the static pre-render).
    socket =
      if connected?(socket) do
        ColloqWeb.Endpoint.subscribe("forum:topic:#{topic.id}")

        # Count one view per real (connected) page load.
        Forum.increment_topic_views(topic.id)

        if current_user do
          broadcast_typing(current_user, topic.id, false)
        end

        socket
        |> mark_topic_read(topic, current_user)
        |> load_reaction_data(topic.posts)
        |> load_user_reactions(topic.posts, current_user)
        |> load_summary(topic)
        |> load_lineup_data(topic.posts)
        |> load_poll_data(topic.posts, current_user)
        |> load_bookmarked_posts(topic.posts, current_user)
        |> load_user_badges(topic.posts)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"slug" => _slug} = _params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  # Fired by the PostImpression hook when a post scrolls into view.
  def handle_event("view-post", %{"id" => id}, socket) do
    viewer = socket.assigns.current_user

    with {post_id, _} <- Integer.parse(to_string(id)),
         %Colloq.Forum.Post{} = post <- Enum.find(flatten_posts(socket.assigns.posts), &(&1.id == post_id)),
         # Reading your own post is not a view: counting it would let anyone
         # inflate their own profile just by scrolling their history.
         true <- is_nil(viewer) or viewer.id != post.user_id do
      Forum.increment_post_view(post)
    end

    {:noreply, socket}
  end

  def handle_event("toggle-sort", _params, socket) do
    next = if socket.assigns.sort == :top, do: :chrono, else: :top
    {:noreply, assign(socket, :sort, next)}
  end

  def handle_event("start-nested-reply", %{"post_id" => post_id}, socket) do
    if socket.assigns.current_user do
      {:noreply, assign(socket, replying_to: String.to_integer(post_id), nested_reply_body: "")}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  def handle_event("cancel-nested-reply", _params, socket) do
    {:noreply, assign(socket, replying_to: nil, nested_reply_body: "")}
  end

  # Quote a comment: insert a blockquote (with attribution) into whichever
  # composer the user is actually working in. `text` is present when the quote
  # came from selecting part of the post body; without it the whole post is
  # quoted.
  def handle_event("quote-post", %{"post_id" => post_id} = params, socket) do
    if socket.assigns.current_user do
      post = Forum.get_post!(String.to_integer(post_id))
      html = quote_html(post, params["text"])

      {:noreply,
       push_event(socket, "tiptap:quote", %{target: quote_target(socket, post.id), html: html})}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  def handle_event("submit-nested-reply", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic
    parent_id = socket.assigns.replying_to

    if user && parent_id && Forum.can_reply?(topic, user) do
      parent_post = Forum.get_post!(parent_id)

      case Forum.create_reply(topic, user, parent_post, %{"body" => body}) do
        {:ok, _post} ->
          topic = Forum.get_topic!(topic.id)

          {:noreply,
           socket
           |> assign(:topic, topic)
           |> assign(:posts, topic.posts)
           |> assign(:replying_to, nil)
           |> assign(:nested_reply_body, "")
           |> load_reaction_data(topic.posts)
           |> load_user_reactions(topic.posts, socket.assigns.current_user)}

        {:error, reason} when reason in [:silenced, :suspended, :banned, :duplicate_post] ->
          {:noreply, put_flash(socket, :error, moderation_block_message(reason))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not post the reply."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You cannot reply to this topic."))}
    end
  end

  def handle_event("reply", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Forum.can_reply?(topic, user) do
      case Forum.create_post(topic, user, %{"body" => body}) do
        {:ok, _post} ->
          topic = Forum.get_topic!(topic.id)

          {:noreply,
           socket
           |> assign(:topic, topic)
           |> assign(:posts, topic.posts)
           |> assign(:reply_body, "")
           |> push_event("tiptap:clear", %{})
           |> load_reaction_data(topic.posts)
           |> load_user_reactions(topic.posts, socket.assigns.current_user)}

        {:error, reason} when reason in [:silenced, :suspended, :banned, :duplicate_post] ->
          {:noreply, put_flash(socket, :error, moderation_block_message(reason))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not post the reply."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You cannot reply to this topic."))}
    end
  end

  defp current_tag_string(socket) do
    socket.assigns
    |> Map.get(:topic_tags, [])
    |> Enum.map_join(",", & &1.name)
  end

  def handle_event("start-edit-topic", _params, socket) do
    if can_edit_topic?(socket.assigns.current_user, socket.assigns.topic) do
      {:noreply,
       socket
       |> assign(:editing_topic, true)
       |> assign(:match_fixtures, load_match_fixtures(socket.assigns.can_manage_match))
       |> assign(:edit_title, socket.assigns.topic.title)
       |> assign(:edit_category_id, socket.assigns.topic.category_id)
       |> assign(:edit_tags, current_tag_string(socket))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-edit-topic", _params, socket) do
    {:noreply, assign(socket, :editing_topic, false)}
  end

  # Pin/unpin the topic (moderators+). Pinned topics sort to the top of lists.
  def handle_event("toggle-pin", _params, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Colloq.Permissions.can?(user, :edit_topics) do
      case Forum.toggle_pin(topic) do
        {:ok, updated} ->
          msg = if updated.pinned, do: gettext("Topic pinned."), else: gettext("Topic unpinned.")
          {:noreply, socket |> assign(:topic, %{topic | pinned: updated.pinned, pinned_at: updated.pinned_at}) |> put_flash(:info, msg)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle-close", _params, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Colloq.Permissions.can?(user, :edit_topics) do
      result = if topic.closed, do: Forum.reopen_topic(topic), else: Forum.close_topic(topic, nil)

      case result do
        {:ok, updated} ->
          msg = if updated.closed, do: gettext("Topic closed."), else: gettext("Topic reopened.")

          {:noreply,
           socket
           |> assign(:topic, %{
             topic
             | closed: updated.closed,
               closed_at: updated.closed_at,
               closed_reason: updated.closed_reason
           })
           |> put_flash(:info, msg)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle-announcement", _params, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Colloq.Permissions.can?(user, :edit_topics) do
      case Forum.set_staff_only(topic, !topic.staff_only) do
        {:ok, updated} ->
          msg =
            if updated.staff_only,
              do: gettext("Announcement mode on — only staff can reply."),
              else: gettext("Announcement mode off.")

          {:noreply,
           socket
           |> assign(:topic, %{topic | staff_only: updated.staff_only})
           |> put_flash(:info, msg)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  # Soft-delete the whole topic (moderator+). It disappears for regular users
  # and shows a recoverable tombstone to staff.
  def handle_event("delete-topic", _params, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Colloq.Permissions.can?(user, :delete_topics) do
      case Forum.delete_topic(topic, user) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:topic, %{
             topic
             | deleted_at: updated.deleted_at,
               deleted_by_id: updated.deleted_by_id,
               deleted_by: user
           })
           |> put_flash(:info, gettext("Topic deleted. Staff can still recover it."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  # Restore a previously soft-deleted topic (moderator+).
  def handle_event("restore-topic", _params, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Colloq.Permissions.can?(user, :delete_topics) do
      case Forum.restore_topic(topic) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> assign(:topic, %{topic | deleted_at: nil, deleted_by_id: nil, deleted_by: nil})
           |> put_flash(:info, gettext("Topic restored."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save-edit-topic", %{"title" => title} = params, socket) do
    topic = socket.assigns.topic

    if can_edit_topic?(socket.assigns.current_user, topic) do
      tag_names =
        (params["tags"] || "")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      attrs = %{"title" => title, "category_id" => params["category_id"], "tags" => tag_names}
      opts = [
        can_create: Tags.can_create?(socket.assigns.current_user),
        tag_limit: Tags.tag_limit(socket.assigns.current_user)
      ]

      case Forum.update_topic(topic, attrs, opts) do
        {:ok, _} ->
          maybe_update_match_thread(topic, params, socket.assigns.can_manage_match)
          topic = Forum.get_topic!(topic.id, socket.assigns.blocked_user_ids)

          {:noreply,
           socket
           |> assign(:topic, topic)
           |> assign(:posts, topic.posts)
           |> assign(:editing_topic, false)
           |> assign(:topic_tags, Tags.get_topic_tags(topic.id))
           |> put_flash(:info, gettext("Topic updated."))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the topic."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You can't edit this topic."))}
    end
  end

  def handle_event("start-edit", %{"post_id" => post_id_str}, socket) do
    post_id = String.to_integer(post_id_str)
    post = Forum.get_post!(post_id)
    user = socket.assigns.current_user

    if user && can_edit_post?(user, post, socket.assigns.topic) do
      {:noreply, assign(socket, editing_post: post_id, editing_body: post.body || "")}
    else
      {:noreply, socket}
    end
  end

  # Authors may edit their own posts only while the topic is open; a closed,
  # archived, or announcement topic freezes them. Staff (:hide_posts) can
  # always edit.
  defp can_edit_post?(nil, _post, _topic), do: false

  defp can_edit_post?(user, post, topic) do
    cond do
      Colloq.Permissions.can?(user, :hide_posts) -> true
      post.user_id == user.id -> Forum.can_reply?(topic, user)
      true -> false
    end
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply, assign(socket, editing_post: nil, editing_body: "")}
  end

  def handle_event("save-edit", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    post_id = socket.assigns.editing_post
    post = post_id && Forum.get_post!(post_id)

    cond do
      is_nil(post) ->
        {:noreply, socket}

      can_edit_post?(user, post, socket.assigns.topic) ->
        case Forum.update_post(post, %{"body" => body}) do
          {:ok, _} ->
            topic = Forum.get_topic!(socket.assigns.topic.id)

            {:noreply,
             socket
             |> assign(:topic, topic)
             |> assign(:posts, topic.posts)
             |> assign(:editing_post, nil)
             |> assign(:editing_body, "")
             |> put_flash(:info, gettext("Comment updated."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update the comment."))}
        end

      true ->
        {:noreply, put_flash(socket, :error, gettext("You can't edit this comment."))}
    end
  end

  def handle_event("delete-post", %{"post_id" => post_id_str}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic
    post = Forum.get_post!(String.to_integer(post_id_str))

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, gettext("You must be logged in."))}

      post.user_id == user.id or Colloq.Permissions.can?(user, :hide_posts) ->
        # Author removing their own post is a plain deletion; a moderator
        # removing someone else's is a moderation hide (shows in the queue).
        if post.user_id == user.id do
          {:ok, _} = Forum.delete_post(post, user)
        else
          {:ok, _} = Colloq.Moderation.hide_post(post, user)
        end

        topic = Forum.get_topic!(topic.id)

        {:noreply,
         socket
         |> assign(:topic, topic)
         |> assign(:posts, topic.posts)
         |> load_reaction_data(topic.posts)
         |> load_user_reactions(topic.posts, user)
         |> put_flash(:info, gettext("Comment deleted."))}

      true ->
        {:noreply, put_flash(socket, :error, gettext("You can't delete this comment."))}
    end
  end

  def handle_event("reaction", %{"post_id" => post_id_str, "emoji" => emoji}, socket) do
    user = socket.assigns.current_user

    if user do
      post_id = String.to_integer(post_id_str)

      case Reactions.toggle_reaction(post_id, user.id, emoji) do
        {:error, :own_post} ->
          {:noreply,
           put_flash(socket, :error, gettext("You can't react to your own comment."))}

        result ->
          user_reactions =
            Map.put(
              socket.assigns.user_reactions,
              post_id,
              Reactions.user_reactions(post_id, user.id)
            )

          socket = assign(socket, :user_reactions, user_reactions)

          # Tell the client to burst *this* pill. Only on add — removing a
          # reaction shouldn't celebrate. Pushed events are dispatched after
          # the DOM patch, so a pill created by this same diff is mounted and
          # listening by the time it arrives.
          socket =
            if match?({:ok, :added, _}, result) do
              push_event(socket, "reaction:burst", %{post_id: post_id, emoji: emoji})
            else
              socket
            end

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("typing", _params, socket) do
    user = socket.assigns.current_user

    if user do
      broadcast_typing(user, socket.assigns.topic.id, true)
    end

    {:noreply, socket}
  end

  def handle_event("stopped_typing", _params, socket) do
    user = socket.assigns.current_user

    if user do
      broadcast_typing(user, socket.assigns.topic.id, false)
    end

    {:noreply, socket}
  end

  def handle_event("set-notification-level", %{"level" => level}, socket) do
    user = socket.assigns.current_user

    if user && level in Colloq.Subscriptions.TopicSubscription.levels() do
      Colloq.Subscriptions.set_level(user.id, socket.assigns.topic.id, level)
      {:noreply, assign(socket, :notification_level, level)}
    else
      {:noreply, socket}
    end
  end

  # Bookmark event — toggles a bookmark on the whole topic for the current user.
  def handle_event("toggle-topic-bookmark", _params, socket) do
    user = socket.assigns.current_user

    if user do
      case Colloq.Bookmarks.toggle_topic_bookmark(user.id, socket.assigns.topic) do
        {:ok, state} ->
          {:noreply,
           socket
           |> assign(:topic_bookmarked, state == :created)
           |> put_flash(
             :info,
             if(state == :created, do: gettext("Topic bookmarked."), else: gettext("Bookmark removed."))
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not bookmark the topic."))}
      end
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  # Flag/report events — show/hide the reason picker and submit to Moderation.
  def handle_event("show-flag", %{"post_id" => post_id}, socket) do
    {:noreply, assign(socket, :show_flag_for, String.to_integer(post_id))}
  end

  def handle_event("hide-flag", _params, socket) do
    {:noreply, assign(socket, :show_flag_for, nil)}
  end

  def handle_event("flag-post", %{"post_id" => post_id, "reason" => reason}, socket) do
    user = socket.assigns.current_user

    if user do
      case Colloq.Moderation.flag_post(String.to_integer(post_id), user.id, reason) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_flag_for, nil)
           |> put_flash(:info, gettext("Report submitted. Thank you."))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:show_flag_for, nil)
           |> put_flash(:error, gettext("Could not submit report."))}
      end
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  # Open the "warn author" dialog so the moderator can explain why.
  def handle_event("open-warn", %{"user_id" => user_id, "username" => username}, socket) do
    if Colloq.Permissions.can?(socket.assigns.current_user, :warn_users) do
      {:noreply,
       assign(socket, :warning_target, %{id: String.to_integer(user_id), username: username})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-warn", _params, socket) do
    {:noreply, assign(socket, :warning_target, nil)}
  end

  def handle_event("confirm-warn", %{"reason" => reason}, socket) do
    actor = socket.assigns.current_user
    target_ref = socket.assigns.warning_target

    if target_ref && Colloq.Permissions.can?(actor, :warn_users) do
      target = Colloq.Accounts.get_user!(target_ref.id)

      case Colloq.Moderation.warn_user(actor, target, reason) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> assign(:warning_target, nil)
           |> put_flash(:info, mod_action_message("warn", target))}

        {:error, :forbidden} ->
          {:noreply,
           socket
           |> assign(:warning_target, nil)
           |> put_flash(
             :error,
             gettext("You can't moderate a user of equal or higher rank.")
           )}

        {:error, :unauthorized} ->
          {:noreply,
           socket
           |> assign(:warning_target, nil)
           |> put_flash(:error, gettext("You don't have permission for this action."))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:warning_target, nil)
           |> put_flash(:error, gettext("Action failed."))}
      end
    else
      {:noreply, assign(socket, :warning_target, nil)}
    end
  end

  # Inline moderator actions on a post's author (silence / suspend / ban).
  # The Moderation context re-checks permissions; we surface the outcome.
  def handle_event("mod-action", %{"action" => action, "user_id" => user_id}, socket) do
    actor = socket.assigns.current_user
    target = Colloq.Accounts.get_user!(String.to_integer(user_id))

    result =
      case action do
        "warn" -> Colloq.Moderation.warn_user(actor, target)
        "silence" -> Colloq.Moderation.silence_user(actor, target, "1_day", nil)
        "suspend" -> Colloq.Moderation.suspend_user(actor, target, "3_days", nil)
        "ban" -> Colloq.Moderation.ban_user(actor, target, nil)
        _ -> {:error, :unknown_action}
      end

    case result do
      {:ok, _user} ->
        {:noreply, put_flash(socket, :info, mod_action_message(action, target))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, gettext("You can't moderate a user of equal or higher rank."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You don't have permission for this action."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Action failed."))}
    end
  end

  # Share event
  def handle_event("copy-link", %{"post_id" => post_id}, socket) do
    url = post_url(socket.assigns.topic.id, post_id)

    # push_event/3 returns a *new* socket. The old code called it and threw the
    # result away, replying with the original socket — so the browser never got
    # the event and nothing was ever copied, while the flash still cheerfully
    # said "Link copied!".
    {:noreply,
     socket
     |> push_event("copy-to-clipboard", %{text: url})
     |> put_flash(:info, gettext("Link copied!"))}
  end

  @doc """
  Canonical permalink to a post.

  One definition, used by the clipboard handler and every share link, so they
  can't drift apart.
  """
  def post_url(topic_id, post_id) do
    "#{ColloqWeb.Endpoint.url()}/t/#{topic_id}#post-#{post_id}"
  end

  @doc """
  A share URL with its parameters properly form-encoded.

  `URI.encode/1` is for whole URIs and leaves `#`, `&` and `?` intact — so the
  permalink's `#post-N` fragment swallowed everything after it. On the Twitter
  intent that meant `&text=` landed inside the fragment and the tweet text was
  dropped silently. Query *parameters* need `encode_www_form/1`.
  """
  def share_url(base, params) do
    base <> "?" <> URI.encode_query(params)
  end

  # "Summarize" — opens the panel. A stored summary is shown as-is (no LLM
  # call); only generate when there's nothing to show yet.
  def handle_event("show-summary", _params, socket) do
    cond do
      is_nil(socket.assigns.current_user) ->
        {:noreply, push_redirect(socket, to: "/login")}

      socket.assigns.summary ->
        {:noreply, assign(socket, show_summary: true)}

      true ->
        {:noreply, socket |> assign(:show_summary, true) |> request_summary()}
    end
  end

  # "Regenerate" — always re-runs the summarizer, even if one is stored.
  def handle_event("generate-summary", _params, socket) do
    if socket.assigns.current_user do
      {:noreply, socket |> assign(:show_summary, true) |> request_summary()}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  # Only hides the panel — the summary itself is kept so reopening is instant.
  def handle_event("dismiss-summary", _params, socket) do
    {:noreply, assign(socket, show_summary: false, summary_unavailable: false)}
  end

  # Enqueues an Oban job that broadcasts "summary_ready" when done.
  defp request_summary(socket) do
    if Colloq.Workers.TopicSummarizerWorker.configured?() do
      %{user_id: socket.assigns.current_user.id, topic_id: socket.assigns.topic.id}
      |> Colloq.Workers.TopicSummarizerWorker.new()
      |> Oban.insert()

      assign(socket, summary_loading: true, summary_unavailable: false)
    else
      assign(socket, summary_unavailable: true, summary_loading: false)
    end
  end

  # Poll events — these manage the inline poll creation form and voting.
  # Polls are attached to a post: the form is toggled open/closed, options
  # can be added/removed (min 2, max 10), and submitted together with the
  # post body. Voting is one-vote-per-user per poll.
  def handle_event("toggle-poll-form", _params, socket) do
    {:noreply, assign(socket, :show_poll_form, !socket.assigns.show_poll_form)}
  end

  # --- Lineup composer ("the XI I'd play") ---
  # Squads are only queried once the form is actually opened.
  def handle_event("toggle-lineup-form", _params, socket) do
    if socket.assigns.show_lineup_form do
      {:noreply, assign(socket, :show_lineup_form, false)}
    else
      teams = Colloq.Sofascore.teams_with_players() |> Enum.filter(& &1.key)
      team_id = socket.assigns.lineup_team_id || (List.first(teams) && List.first(teams).id)

      {:noreply,
       socket
       |> assign(:show_lineup_form, true)
       |> assign(:lineup_teams, teams)
       |> assign(:lineup_team_id, team_id)
       |> rebuild_lineup()}
    end
  end

  def handle_event("select-lineup-team", %{"team_id" => id}, socket) do
    {:noreply, socket |> assign(:lineup_team_id, String.to_integer(id)) |> rebuild_lineup()}
  end

  def handle_event("select-lineup-formation", %{"formation" => formation}, socket) do
    if Colloq.Lineups.valid_formation?(formation) do
      {:noreply, socket |> assign(:lineup_formation, formation) |> rebuild_lineup()}
    else
      {:noreply, socket}
    end
  end

  # Swap one slot's player — this is the "what *you* think" part.
  def handle_event("swap-lineup-player", %{"slot" => slot, "player_id" => player_id}, socket) do
    slot = String.to_integer(slot)
    player = Enum.find(socket.assigns.lineup_squad, &(&1.id == String.to_integer(player_id)))

    slots = List.update_at(socket.assigns.lineup_slots, slot, &Map.put(&1, :player, player))
    {:noreply, assign(socket, :lineup_slots, slots)}
  end

  def handle_event("submit-with-lineup", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && Forum.can_reply?(topic, user) && socket.assigns.lineup_team_id do
      case Forum.create_post(topic, user, %{"body" => body}) do
        {:ok, post} ->
          # Surface a failure instead of silently posting without the board.
          case Forum.create_lineup(post, %{
                 team_id: socket.assigns.lineup_team_id,
                 formation: socket.assigns.lineup_formation,
                 players: snapshot_players(socket.assigns.lineup_slots)
               }) do
            {:ok, _} ->
              :ok

            {:error, changeset} ->
              Logger.warning("[Lineup] could not attach to post #{post.id}: #{inspect(changeset.errors)}")
          end

          topic = Forum.get_topic!(topic.id)

          {:noreply,
           socket
           |> assign(:topic, topic)
           |> assign(:posts, topic.posts)
           |> assign(:show_lineup_form, false)
           |> push_event("tiptap:clear", %{})
           |> load_reaction_data(topic.posts)
           |> load_user_reactions(topic.posts, user)
           |> load_lineup_data(topic.posts)}

        {:error, reason} when reason in [:silenced, :suspended, :banned, :duplicate_post] ->
          {:noreply, put_flash(socket, :error, moderation_block_message(reason))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not post the reply."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You cannot reply to this topic."))}
    end
  end

  defp rebuild_lineup(socket) do
    socket = assign(socket, :lineup_colors, Colloq.Sofascore.team_colors(socket.assigns.lineup_team_id))

    case socket.assigns.lineup_team_id do
      nil ->
        socket |> assign(:lineup_slots, []) |> assign(:lineup_squad, [])

      team_id ->
        %{slots: slots} = Colloq.Lineups.build(team_id, socket.assigns.lineup_formation)

        socket
        |> assign(:lineup_slots, slots)
        |> assign(:lineup_squad, Colloq.Sofascore.list_by_team(team_id))
    end
  end

  # Freeze the chosen XI onto the post: names are stored alongside ids so an
  # old post still reads correctly if a player row is ever removed.
  defp snapshot_players(slots) do
    slots
    |> Enum.with_index()
    |> Enum.map(fn {slot, index} ->
      %{
        "slot" => index,
        "role" => to_string(slot.role),
        "name" => slot.player && slot.player.name,
        "player_id" => slot.player && slot.player.id
      }
    end)
  end

  def handle_event("update-poll-question", %{"value" => question}, socket) do
    {:noreply, assign(socket, :poll_question, question)}
  end

  def handle_event("update-poll-option", %{"index" => idx, "value" => value}, socket) do
    options = List.replace_at(socket.assigns.poll_options, String.to_integer(idx), value)
    {:noreply, assign(socket, :poll_options, options)}
  end

  def handle_event("toggle-poll-anonymous", _params, socket) do
    {:noreply, assign(socket, :poll_anonymous, !socket.assigns.poll_anonymous)}
  end

  def handle_event("add-poll-option", _params, socket) do
    if length(socket.assigns.poll_options) < 10 do
      {:noreply, assign(socket, :poll_options, socket.assigns.poll_options ++ [""])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove-poll-option", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    if length(socket.assigns.poll_options) > 2 do
      options = List.delete_at(socket.assigns.poll_options, idx)
      {:noreply, assign(socket, :poll_options, options)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("submit-with-poll", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && !topic.closed && !topic.archived do
      question = socket.assigns.poll_question
      options = socket.assigns.poll_options |> Enum.reject(&(&1 == ""))

      case Forum.create_post(topic, user, %{"body" => body}) do
        {:ok, post} ->
          if question != "" && length(options) >= 2 do
            Forum.create_poll(post, question, options, anonymous: socket.assigns.poll_anonymous)

            ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "poll_updated", %{
              post_id: post.id
            })
          end

          topic = Forum.get_topic!(topic.id)

          {:noreply,
           socket
           |> assign(:topic, topic)
           |> assign(:posts, topic.posts)
           |> assign(:reply_body, "")
           |> assign(:show_poll_form, false)
           |> assign(:poll_question, "")
           |> assign(:poll_options, ["", ""])
           |> assign(:poll_anonymous, false)
           |> load_reaction_data(topic.posts)
           |> load_user_reactions(topic.posts, user)
           |> load_poll_data(topic.posts, user)}

        {:error, reason} when reason in [:silenced, :suspended, :banned, :duplicate_post] ->
          {:noreply, put_flash(socket, :error, moderation_block_message(reason))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not post the reply."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You cannot reply to this topic."))}
    end
  end

  # Cast a vote on a poll option. After a successful vote, broadcasts
  # "poll_updated" on the topic PubSub channel so all connected clients
  # refresh their poll results in real-time.
  def handle_event("vote-poll", %{"poll_id" => poll_id, "option_id" => option_id}, socket) do
    user = socket.assigns.current_user

    if user do
      poll = Repo.get!(Forum.Poll, poll_id)
      option = Repo.get!(Forum.PollOption, option_id)

      case Forum.cast_vote(poll, option, user) do
        {:ok, _} ->
          topic = Forum.get_topic!(socket.assigns.topic.id)

          ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "poll_updated", %{
            poll_id: poll_id
          })

          {:noreply,
           socket
           |> assign(:topic, topic)
           |> assign(:posts, topic.posts)
           |> load_poll_data(topic.posts, user)}

        {:error, :already_voted} ->
          {:noreply, put_flash(socket, :error, gettext("You already voted in this poll."))}

        {:error, :poll_closed} ->
          {:noreply, put_flash(socket, :error, gettext("This poll is closed."))}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  @impl true
  # PubSub: a new post was created — reload the topic tree (including nested
  # replies) and refresh reaction data.
  #
  # `create_post` uses a plain `broadcast`, so the author's OWN client receives
  # this too — but that client already re-rendered the post from its reply
  # handler. Reloading again would render the whole list a second time
  # milliseconds later, which flickers. So if the post is already on screen,
  # this is a no-op.
  def handle_info(%{event: "new_post", payload: payload}, socket) do
    if already_rendered?(socket.assigns.posts, payload[:post_id]) do
      {:noreply, socket}
    else
      handle_new_post(socket)
    end
  end

  # PubSub: a post was deleted (hidden). Reload so it disappears in real time.
  # The deleter already re-rendered from their own handler and no longer has the
  # post on screen, so for them this is a no-op — only other viewers reload.
  def handle_info(%{event: "post_deleted", payload: payload}, socket) do
    if already_rendered?(socket.assigns.posts, payload[:post_id]) do
      handle_new_post(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{event: "reaction_updated", payload: %{post_id: post_id, counts: counts}}, socket) do
    {:noreply,
     socket
     |> assign(:reaction_data, Map.put(socket.assigns.reaction_data, post_id, counts))}
  end

  # ResultaBot pushes the score with every poll, so the banner updates without
  # the page doing its own polling — and without a refresh.
  def handle_info(%{event: "match_score", payload: %{match: match}}, socket) do
    {:noreply, assign(socket, :match, match)}
  end

  def handle_info(%{event: "match_event", payload: _payload}, socket) do
    topic = Forum.get_topic!(socket.assigns.topic.id)

    {:noreply,
     socket
     |> assign(:topic, topic)
     |> assign(:posts, topic.posts)
     |> load_reaction_data(topic.posts)
     |> load_user_reactions(topic.posts, socket.assigns.current_user)}
  end

  # PubSub: poll results changed (someone voted) — reload poll data.
  def handle_info(%{event: "poll_updated", payload: _payload}, socket) do
    topic = Forum.get_topic!(socket.assigns.topic.id)

    {:noreply,
     socket
     |> assign(:topic, topic)
     |> assign(:posts, topic.posts)
     |> load_poll_data(topic.posts, socket.assigns.current_user)}
  end

  def handle_info(%{event: "match_mode_changed", payload: %{mode: mode}}, socket) do
    {:noreply, assign(socket, :match_mode, mode)}
  end

  # PubSub: typing indicator — add the user to the list and schedule a
  # timeout so they disappear if the client stops sending heartbeats.
  def handle_info(%{event: "user_typing", payload: %{user_id: user_id, username: username}}, socket) do
    typing = socket.assigns.typing_users |> List.keydelete(user_id, 0) |> List.keystore(user_id, 0, {user_id, username})

    Process.send_after(self(), {:typing_timeout, user_id}, @typing_timeout)

    {:noreply, assign(socket, :typing_users, typing)}
  end

  def handle_info(%{event: "user_stopped_typing", payload: %{user_id: user_id}}, socket) do
    typing = List.keydelete(socket.assigns.typing_users, user_id, 0)
    {:noreply, assign(socket, :typing_users, typing)}
  end

  def handle_info({:typing_timeout, user_id}, socket) do
    typing = List.keydelete(socket.assigns.typing_users, user_id, 0)
    {:noreply, assign(socket, :typing_users, typing)}
  end

  # PubSub: the Oban summarizer job finished. This is broadcast to *everyone*
  # viewing the topic, so we load the data but never pop the panel open for
  # readers who didn't ask (their `show_summary` stays false).
  def handle_info(%{event: "summary_ready", payload: payload}, socket) do
    {:noreply,
     socket
     |> assign(:summary, payload.summary)
     |> assign(:summary_at, Map.get(payload, :generated_at))
     |> assign(:summary_model, Map.get(payload, :model))
     |> assign(:summary_post_number, Map.get(payload, :post_number))
     |> assign(:summary_loading, false)}
  end

  # PubSub: the summarizer job failed. Also broadcast to everyone viewing the
  # topic, so only the reader who actually asked gets the error.
  def handle_info(%{event: "summary_failed", payload: _payload}, socket) do
    if socket.assigns.summary_loading do
      {:noreply,
       socket
       |> assign(:summary_loading, false)
       |> put_flash(:error, gettext("Could not generate the summary. Check the LLM provider settings."))}
    else
      {:noreply, socket}
    end
  end

  # Shared reload for structural changes (new post / deletion): rebuild the
  # topic tree and refresh reaction/poll/bookmark/badge data.
  defp handle_new_post(socket) do
    topic = Forum.get_topic!(socket.assigns.topic.id, socket.assigns.blocked_user_ids)
    user = socket.assigns.current_user

    # The reader is looking at the topic right now, so a post that just arrived
    # counts as read — keep their marker current so the next visit doesn't flag
    # posts they already saw as unread.
    if user do
      max_number = topic.posts |> flatten_posts() |> Enum.map(& &1.post_number) |> Enum.max(fn -> 0 end)
      Reads.mark_read(user.id, topic.id, max_number)
    end

    {:noreply,
     socket
     |> assign(:topic, topic)
     |> assign(:posts, topic.posts)
     |> load_reaction_data(topic.posts)
     |> load_user_reactions(topic.posts, user)
     |> load_poll_data(topic.posts, user)
     |> load_bookmarked_posts(topic.posts, user)
     |> load_user_badges(topic.posts)}
  end

  defp already_rendered?(_posts, nil), do: false

  defp already_rendered?(posts, post_id) do
    posts |> flatten_posts() |> Enum.any?(&(&1.id == post_id))
  end

  # Match threads carry a Sofascore event id; anything else has no banner.
  # A failed fetch is not fatal — the thread still renders, just without the
  # score bar, which beats 500-ing a live match thread because an unofficial
  # API blipped.
  defp assign_match_banner(socket, %{is_match_thread: true, match_id: match_id})
       when is_binary(match_id) and match_id != "" do
    case Integer.parse(match_id) do
      {event_id, _} ->
        case Colloq.Sofascore.event(event_id) do
          {:ok, event} -> assign(socket, :match, Colloq.Sofascore.match_summary(event))
          {:error, _} -> assign(socket, :match, nil)
        end

      :error ->
        assign(socket, :match, nil)
    end
  end

  defp assign_match_banner(socket, _topic), do: assign(socket, :match, nil)

  # Racing's upcoming fixtures for the picker. Only fetched for someone who can
  # actually use it, and never fatal: a Sofascore blip should leave the topic
  # editor working, just without the dropdown.
  defp load_match_fixtures(false), do: []

  defp load_match_fixtures(true) do
    Colloq.Sofascore.upcoming_fixtures(Colloq.Sofascore.racing_team_id())
  rescue
    _ -> []
  end

  # Match-thread fields are staff-only and live outside update_topic/3, which
  # handles title/category/tags. Unticking the box clears the fixture too —
  # otherwise a stale match_id stays behind and ResultaBot would still accept
  # /resultabot in a thread no longer marked as a match.
  defp maybe_update_match_thread(_topic, _params, false), do: :ok

  defp maybe_update_match_thread(topic, params, true) do
    match? = params["is_match_thread"] == "on"
    match_id = String.trim(params["match_id"] || "")

    attrs =
      if match? and match_id != "" do
        %{
          is_match_thread: true,
          match_id: match_id,
          match_mode: topic.match_mode || "prematch"
        }
      else
        %{is_match_thread: false, match_id: nil, match_mode: nil}
      end

    topic |> Ecto.Changeset.change(attrs) |> Repo.update()
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  # Load the persisted summary (if any) from the topic.
  defp load_summary(socket, topic) do
    if topic.summary do
      socket
      |> assign(:summary, topic.summary)
      |> assign(:summary_at, topic.summary_generated_at)
      |> assign(:summary_model, topic.summary_model)
      |> assign(:summary_post_number, topic.summary_post_number)
    else
      socket
    end
  end

  # Read-only: compare the user's last-read post_number against the posts on
  # screen to decide where the "New replies" divider goes (first_unread_id) and
  # how many new posts there are (unread_count, for the "jump to new" pill). No
  # DB writes — safe to run in the static pre-render so both are in the initial
  # HTML (no pop-in). Nothing auto-scrolls: the reader taps the pill to jump.
  # Anonymous readers, first visits and fully-read topics resolve to none.
  defp assign_unread(socket, _topic, nil, _to_latest), do: assign_nil_unread(socket)

  defp assign_unread(socket, topic, user, to_latest) do
    last = Reads.last_read(user.id, topic.id)

    # Posts newer than last read that aren't the reader's own — no point
    # flagging someone's own replies as "new".
    unread =
      topic.posts
      |> flatten_posts()
      |> Enum.filter(&(&1.post_number > last && &1.user_id != user.id))
      |> Enum.sort_by(& &1.post_number)

    first_unread = List.first(unread)

    if last > 0 && first_unread do
      socket
      |> assign(:first_unread_id, first_unread.id)
      |> assign(:unread_count, length(unread))
      # On a normal revisit, land the reader on the divider so they read forward
      # from where they left. When they explicitly asked for the latest post
      # (activity-time link), honour that instead — the pill still lets them jump
      # up to the new posts.
      |> assign(:scroll_anchor, if(to_latest, do: nil, else: "unread-divider"))
    else
      assign_nil_unread(socket)
    end
  end

  defp assign_nil_unread(socket) do
    socket
    |> assign(:unread_count, 0)
    |> assign(:first_unread_id, nil)
    |> assign(:scroll_anchor, nil)
  end

  # The write half: once the client is connected, record the newest post_number
  # as read so the next visit starts fresh.
  defp mark_topic_read(socket, _topic, nil), do: socket

  defp mark_topic_read(socket, topic, user) do
    max_number = topic.posts |> flatten_posts() |> Enum.map(& &1.post_number) |> Enum.max(fn -> 0 end)
    Reads.mark_read(user.id, topic.id, max_number)
    socket
  end

  @doc "Whether the shown summary predates the topic's current posts."
  def summary_outdated?(assigns) do
    assigns.summary && assigns.summary_post_number &&
      assigns.topic.posts_count > assigns.summary_post_number
  end

  defp load_reaction_data(socket, posts) do
    reaction_data = collect_reaction_data(posts)
    assign(socket, :reaction_data, reaction_data)
  end

  defp load_user_reactions(socket, _posts, nil), do: socket

  defp load_user_reactions(socket, posts, user) do
    user_reactions = collect_user_reactions(posts, user.id)
    assign(socket, :user_reactions, user_reactions)
  end

  defp load_lineup_data(socket, posts) do
    assign(socket, :lineup_data, Forum.preload_lineups(collect_post_ids(posts)))
  end

  defp load_poll_data(socket, posts, user) do
    post_ids = collect_post_ids(posts)
    poll_data = Forum.preload_polls(post_ids)

    poll_results =
      Map.new(poll_data, fn {post_id, poll} ->
        {post_id, Forum.poll_results(poll)}
      end)

    user_poll_votes =
      if user do
        Map.new(poll_data, fn {post_id, poll} ->
          {post_id, Forum.user_poll_votes(poll.id, user.id)}
        end)
      else
        %{}
      end

    socket
    |> assign(:poll_data, poll_results)
    |> assign(:user_poll_votes, user_poll_votes)
  end

  defp load_bookmarked_posts(socket, _posts, nil), do: socket

  defp load_bookmarked_posts(socket, posts, user) do
    post_ids = collect_post_ids(posts)
    bookmarked = Colloq.Bookmarks.user_bookmarked_post_ids(user.id, post_ids)
    assign(socket, :bookmarked_posts, Map.new(bookmarked, &{&1, true}))
  end

  defp collect_post_ids(posts) when is_list(posts) do
    Enum.flat_map(posts, fn post ->
      [post.id | collect_post_ids(post.replies)]
    end)
  end

  defp load_user_badges(socket, posts) do
    user_ids = collect_user_ids(posts)
    user_badges = Colloq.Badges.preload_display_badges(user_ids)
    assign(socket, :user_badges, user_badges)
  end

  defp collect_user_ids(posts) when is_list(posts) do
    Enum.flat_map(posts, fn post ->
      user_id = if post.user, do: [post.user.id], else: []
      user_id ++ collect_user_ids(post.replies)
    end)
  end

  defp collect_reaction_data(posts) when is_list(posts) do
    Enum.reduce(posts, %{}, fn post, acc ->
      acc
      |> Map.put(post.id, Reactions.reaction_counts(post.id))
      |> Map.merge(collect_reaction_data(post.replies))
    end)
  end

  defp collect_user_reactions(posts, user_id) when is_list(posts) do
    Enum.reduce(posts, %{}, fn post, acc ->
      acc
      |> Map.put(post.id, Reactions.user_reactions(post.id, user_id))
      |> Map.merge(collect_user_reactions(post.replies, user_id))
    end)
  end

  defp broadcast_typing(user, topic_id, is_typing) do
    event = if is_typing, do: "user_typing", else: "user_stopped_typing"

    ColloqWeb.Endpoint.broadcast_from(self(), "forum:topic:#{topic_id}",
      event, %{user_id: user.id, username: user.username})
  end

  def can_reply?(assigns) do
    assigns.current_user && Forum.can_reply?(assigns.topic, assigns.current_user)
  end

  def notification_levels, do: ~w(watching tracking normal muted)

  def level_icon("watching"), do: "bell-ring"
  def level_icon("muted"), do: "bell-off"
  def level_icon(_), do: "bell"

  def level_label("watching"), do: gettext("Watching")
  def level_label("tracking"), do: gettext("Tracking")
  def level_label("muted"), do: gettext("Muted")
  def level_label(_), do: gettext("Normal")

  def level_description("watching"),
    do: gettext("You'll be notified of every new reply in this topic.")

  def level_description("tracking"),
    do:
      gettext(
        "You'll be notified if someone mentions your @name or replies to you. (A new-reply count is coming.)"
      )

  def level_description("muted"),
    do: gettext("You'll never be notified, and this topic won't appear in Latest.")

  def level_description(_),
    do: gettext("You'll be notified if someone mentions your @name or replies to you.")

  @doc "The topic author or a moderator+ (edit_topics) may edit the topic."
  def can_edit_topic?(nil, _topic), do: false

  def can_edit_topic?(user, topic) do
    topic.user_id == user.id || Colloq.Permissions.can?(user, :edit_topics)
  end

  @doc """
  Sanitize a stored post body before rendering it as raw HTML.

  Post bodies are stored as HTML (rendered from Tiptap JSON) and come from
  untrusted sources — forum users and LLM bots — so they must be sanitized
  on the way out to prevent stored XSS. Strips scripts, event handlers and
  other dangerous markup while keeping basic formatting.
  """
  def render_body(nil), do: Phoenix.HTML.raw("")

  def render_body(body) when is_binary(body) do
    body |> render_body_string() |> Phoenix.HTML.raw()
  end

  defp render_body_string(body) when is_binary(body) do
    body
    |> autolink()
    # html5 scrubber keeps <img> (for uploads) while still stripping scripts/handlers.
    |> HtmlSanitizeEx.html5()
    # Runs after sanitizing so the mention markup (and its class) isn't stripped.
    # The captured username is [a-zA-Z0-9_] only, so the injected HTML is safe.
    |> link_mentions()
    # Replace :shortcode: with custom-emoji <img> (also post-sanitize; the
    # emoji name charset and image URL are validated on creation).
    |> Colloq.Emojis.render_shortcodes()
    # Wrap NSFW-flagged images so they render blurred behind a warning. Done on
    # the server (not just the PostBody hook) so the blur is present in the
    # initial HTML — no flash of the raw image before JS runs, and it survives
    # LiveView DOM patches.
    |> wrap_sensitive_media()
  end

  # Wraps every `<img data-sensitive>` in a `.sensitive-media` span so CSS can
  # blur it and overlay a "click to reveal" veil (see app.css + the PostBody
  # hook, which only toggles the reveal class). The <img> markup was already
  # produced by the html5 sanitizer, so re-wrapping it is safe.
  defp wrap_sensitive_media(html) do
    String.replace(
      html,
      ~r/<img\b[^>]*\bdata-sensitive\b[^>]*>/i,
      &~s(<span class="sensitive-media">#{&1}</span>)
    )
  end

  # Like render_body/1, but replaces quoted URLs with their preview card so the
  # onebox renders INSIDE the quote (in place of the link) rather than below.
  def render_post_body(body, cards, blocked_ids \\ MapSet.new())

  def render_post_body(nil, _cards, _blocked_ids), do: Phoenix.HTML.raw("")

  def render_post_body(body, cards, blocked_ids) when is_binary(body) do
    html = render_body_string(body)

    html =
      Enum.reduce(cards, html, fn %{data: e}, acc ->
        esc = Regex.escape(e.url)
        # Replace the rendered <a …href="URL"…>…</a> with the card markup.
        String.replace(acc, ~r/<a[^>]*href="#{esc}"[^>]*>.*?<\/a>/is, og_card_html(e))
      end)

    html = collapse_blocked_quotes(html, blocked_ids)

    Phoenix.HTML.raw(html)
  end

  # Collapse quotes whose author the viewer has blocked/ignored behind a
  # click-to-reveal <details>, so a blocked user's words don't leak through
  # someone else's quote. Quotes carry the author id via `data-quote-user-id`
  # (set by quote_html/1); quotes are never nested, so a non-greedy match to the
  # first </blockquote> is safe. No-op when nothing is blocked.
  defp collapse_blocked_quotes(html, blocked_ids) do
    if Enum.empty?(blocked_ids) do
      html
    else
      Regex.replace(
        ~r/<blockquote\b[^>]*\bdata-quote-user-id="(\d+)"[^>]*>.*?<\/blockquote>/is,
        html,
        fn full, id ->
          if MapSet.member?(blocked_ids, String.to_integer(id)) do
            ~s(<details class="blocked-quote my-2 rounded-lg border border-border bg-surface-alt px-3 py-2">) <>
              ~s(<summary class="cursor-pointer text-xs text-muted select-none">) <>
              gettext("Quote from a user you've blocked — click to show") <>
              ~s(</summary><div class="mt-2">#{full}</div></details>)
          else
            full
          end
        end
      )
    end
  end

  # Raw HTML for an Open Graph preview card (safe to inject post-sanitisation:
  # every dynamic value is HTML-escaped). Mirrors the media_embed :og markup.
  defp og_card_html(e) do
    esc = fn v -> v |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string() end

    img =
      if e.image_url && e.image_url != "" do
        ~s(<img src="#{esc.(e.image_url)}" alt="" class="link-card-img w-28 sm:w-40 object-cover flex-shrink-0 self-stretch bg-surface" loading="lazy" />)
      else
        ""
      end

    host =
      if e.host && e.host != "" do
        ~s(<span class="block text-xs text-muted truncate mb-0.5">#{esc.(e.host)}</span>)
      else
        ""
      end

    desc =
      if e.description && e.description != "" do
        ~s(<span class="block text-xs text-muted mt-1 line-clamp-2">#{esc.(e.description)}</span>)
      else
        ""
      end

    ~s(<a href="#{esc.(e.url)}" target="_blank" rel="noopener noreferrer" class="flex rounded-xl border border-border bg-surface overflow-hidden hover:border-border-hover transition-colors max-w-xl no-underline my-2">#{img}<span class="p-3 min-w-0 flex-1 block">#{host}<span class="block text-sm font-semibold text-heading line-clamp-2">#{esc.(e.title)}</span>#{desc}</span></a>)
  end

  # Build the HTML inserted into the composer when quoting a comment.
  # Preserves images and links (basic_html) instead of flattening to plain text,
  # which used to drop images and mash paragraphs together. Nested quotes are
  # stripped to avoid quote-inception.
  # A nested composer open on the quoted post wins over the main one at the
  # bottom of the page — otherwise the quote lands in a box the user can't see
  # and the page scrolls away from where they were typing.
  defp quote_target(socket, post_id) do
    if socket.assigns[:replying_to] == post_id do
      "nested-reply-editor-#{post_id}"
    else
      "reply-editor"
    end
  end

  defp quote_html(post, selection) do
    # Use the real username as the handle so it links to the right profile
    # (display names aren't valid @mentions).
    handle = if post.user, do: post.user.username, else: gettext("someone")
    label = Phoenix.HTML.html_escape("@#{handle}:") |> Phoenix.HTML.safe_to_string()

    inner = selection_inner(selection) || full_body_inner(post)

    # `data-quote-user-id` lets the renderer collapse this quote for viewers who
    # have blocked/ignored the quoted author (see collapse_blocked_quotes/2).
    uid_attr = if post.user, do: ~s( data-quote-user-id="#{post.user.id}"), else: ""

    "<blockquote#{uid_attr}><p><strong>#{label}</strong></p>#{inner}</blockquote><p></p>"
  end

  # Whole-post quote: preserve images and links instead of flattening to plain
  # text, which used to drop images and mash paragraphs together.
  #
  # Scrubbed with `html5/1`, the same scrubber `Post.sanitize_body/1` applies on
  # write — so this is re-scrubbing content that already passed that boundary,
  # not widening it. `basic_html/1` was used here and strips `class`, which cost
  # quoted images their `max-w-full` and let them render at intrinsic size,
  # bigger inside the quote than in the post being quoted.
  defp full_body_inner(post) do
    inner =
      (post.body || "")
      |> strip_blockquotes()
      |> HtmlSanitizeEx.html5()
      |> quote_imagify()
      |> String.trim()

    # Cap very long quotes; re-sanitize after slicing to close any dangling tags.
    if String.length(inner) > @quote_limit do
      (inner |> String.slice(0, @quote_limit) |> HtmlSanitizeEx.html5()) <> "…"
    else
      inner
    end
  end

  # Partial quote from a text selection. The text comes from the reader's
  # browser, so it is treated as untrusted plain text and escaped — never
  # sanitized-as-HTML — and only then rebuilt into paragraphs so multi-paragraph
  # selections keep their breaks. Returns nil when there's nothing usable, so
  # the caller falls back to quoting the whole post.
  defp selection_inner(nil), do: nil

  defp selection_inner(text) when is_binary(text) do
    text = text |> String.trim() |> String.slice(0, @quote_limit)

    case String.split(text, ~r/\n{2,}/, trim: true) do
      [] ->
        nil

      paragraphs ->
        Enum.map_join(paragraphs, fn para ->
          escaped =
            para
            |> String.trim()
            |> Phoenix.HTML.html_escape()
            |> Phoenix.HTML.safe_to_string()
            |> String.replace("\n", "<br />")

          "<p>#{escaped}</p>"
        end)
    end
  end

  defp selection_inner(_), do: nil

  # Inside quotes, image URLs must render as actual images: embed cards are
  # suppressed within quotes, so an image link would otherwise show only as
  # text. Converts image-URL anchors (and bare image URLs) into <img>.
  @image_url ~S/https?:\/\/[^\s"'<>]+\.(?:jpg|jpeg|png|gif|webp)(?:\?[^\s"'<>]*)?/
  # Same classes the composer puts on an uploaded image, so a quoted image is
  # styled like one written directly into a post rather than rendering raw.
  @quote_img_class "rounded-lg max-w-full my-2"
  defp quote_imagify(html) do
    html
    # <a href="…jpg">…</a>  ->  <img src="…jpg">
    |> String.replace(
      ~r/<a\b[^>]*href="(#{@image_url})"[^>]*>.*?<\/a>/is,
      ~s(<img class="#{@quote_img_class}" src="\\1" alt="" />)
    )
    # bare image URL (not already inside an attribute) -> <img>
    |> String.replace(
      ~r/(?<![">=])(#{@image_url})/i,
      ~s(<img class="#{@quote_img_class}" src="\\1" alt="" />)
    )
  end

  # Turn bare http(s) URLs into clickable links (skips ones already in an attribute/tag).
  defp autolink(text) do
    Regex.replace(~r{(?<!["'=>])(https?://[^\s<>"']+)}, text, fn _full, url ->
      # The pattern runs to the next space, so sentence punctuation and a
      # closing bracket get swallowed into the href: a URL ending a sentence
      # linked to "…/page." (404), and a URL inside parentheses — including
      # the `[label](url)` markdown the LLM bots emit — linked to "…/page)".
      {url, trailing} = split_trailing_punctuation(url)

      ~s(<a href="#{url}" target="_blank" rel="noopener noreferrer">#{url}</a>) <> trailing
    end)
  end

  # Punctuation that can never end a URL, peeled off the tail and returned so
  # the caller can re-emit it as plain text after the link.
  @url_trailing_punctuation ~w(. , ; : ! ? " ')

  # Brackets are only trailing punctuation when they're unbalanced. A wiki URL
  # like /wiki/Estadio_(Boca) closes what it opened and must stay intact; the
  # ) in markdown's [label](url) has no opener inside the URL, so it goes.
  @url_brackets %{")" => "(", "]" => "[", "}" => "{"}

  defp split_trailing_punctuation(url, trailing \\ "") do
    last = String.last(url)

    cond do
      last == nil ->
        {url, trailing}

      last in @url_trailing_punctuation ->
        url |> chop() |> split_trailing_punctuation(last <> trailing)

      Map.has_key?(@url_brackets, last) and unbalanced_bracket?(url, last) ->
        url |> chop() |> split_trailing_punctuation(last <> trailing)

      true ->
        {url, trailing}
    end
  end

  defp chop(str), do: String.slice(str, 0, String.length(str) - 1)

  defp unbalanced_bracket?(url, closing) do
    opening = Map.fetch!(@url_brackets, closing)
    count(url, closing) > count(url, opening)
  end

  defp count(str, char), do: str |> String.graphemes() |> Enum.count(&(&1 == char))

  # Turn @username into a link to the user's profile. The negative lookbehind
  # avoids touching emails (foo@bar) and anything already inside a URL/attribute.
  defp link_mentions(html) do
    Regex.replace(
      ~r|(?<![\w./@"'])@([a-zA-Z0-9_]{3,30})|,
      html,
      ~s(<a href="/u/\\1" class="font-medium text-accent hover:underline">@\\1</a>)
    )
  end

  attr :embed, :map, required: true

  def media_embed(%{embed: %{type: :youtube}} = assigns) do
    ~H"""
    <div class="aspect-video w-full max-w-xl rounded-lg overflow-hidden border border-border">
      <iframe
        src={"https://www.youtube-nocookie.com/embed/#{@embed.id}"}
        class="w-full h-full"
        title="YouTube"
        loading="lazy"
        allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
        allowfullscreen
      >
      </iframe>
    </div>
    """
  end

  def media_embed(%{embed: %{type: :vimeo}} = assigns) do
    ~H"""
    <div class="aspect-video w-full max-w-xl rounded-lg overflow-hidden border border-border">
      <iframe
        src={"https://player.vimeo.com/video/#{@embed.id}"}
        class="w-full h-full"
        title="Vimeo"
        loading="lazy"
        allowfullscreen
      >
      </iframe>
    </div>
    """
  end

  def media_embed(%{embed: %{type: :spotify}} = assigns) do
    ~H"""
    <iframe
      src={"https://open.spotify.com/embed/#{@embed.path}"}
      class="w-full max-w-xl rounded-xl border border-border"
      style="height: 152px;"
      loading="lazy"
      title="Spotify"
      allow="autoplay; clipboard-write; encrypted-media; picture-in-picture"
      allowfullscreen
    >
    </iframe>
    """
  end

  def media_embed(%{embed: %{type: :soundcloud}} = assigns) do
    ~H"""
    <iframe
      src={"https://w.soundcloud.com/player/?url=#{URI.encode_www_form(@embed.url)}&color=%233b82f6&auto_play=false&hide_related=true&show_comments=false&visual=false"}
      class="w-full max-w-xl rounded-xl border border-border"
      style="height: 166px;"
      loading="lazy"
      title="SoundCloud"
      allow="autoplay"
    >
    </iframe>
    """
  end

  def media_embed(%{embed: %{type: :og}} = assigns) do
    e = assigns.embed.data
    assigns = assign(assigns, :e, e)

    ~H"""
    <a
      href={@e.url}
      target="_blank"
      rel="noopener noreferrer"
      class="flex rounded-xl border border-border bg-surface-alt overflow-hidden hover:border-border-hover transition-colors max-w-xl no-underline"
    >
      <img
        :if={@e.image_url && @e.image_url != ""}
        src={@e.image_url}
        alt=""
        class="w-28 sm:w-40 object-cover flex-shrink-0 self-stretch bg-surface"
        loading="lazy"
      />
      <span class="p-3 min-w-0 flex-1 block">
        <span :if={@e.host && @e.host != ""} class="block text-xs text-muted truncate mb-0.5">
          <%= @e.host %>
        </span>
        <span class="block text-sm font-semibold text-heading line-clamp-2"><%= @e.title %></span>
        <span :if={@e.description && @e.description != ""} class="block text-xs text-muted mt-1 line-clamp-2">
          <%= @e.description %>
        </span>
      </span>
    </a>
    """
  end

  def media_embed(%{embed: %{type: :image}} = assigns) do
    ~H"""
    <a href={@embed.url} target="_blank" rel="noopener noreferrer" class="block no-underline">
      <img
        src={@embed.url}
        alt=""
        loading="lazy"
        class="rounded-xl border border-border bg-surface-alt max-h-[32rem] max-w-full w-auto object-contain"
      />
    </a>
    """
  end

  def media_embed(%{embed: %{type: :video} = embed} = assigns) do
    assigns = assign(assigns, :src, Map.get(embed, :src, embed.url))
    assigns = assign(assigns, :loop, Map.get(embed, :loop, false))

    ~H"""
    <video
      src={@src}
      controls
      playsinline
      preload="metadata"
      loop={@loop}
      autoplay={@loop}
      muted={@loop}
      class="rounded-xl border border-border bg-black max-h-[32rem] max-w-full w-auto"
    >
    </video>
    """
  end

  def media_embed(%{embed: %{type: :instagram}} = assigns) do
    ~H"""
    <iframe
      src={"https://www.instagram.com/p/#{@embed.id}/embed"}
      class="w-full max-w-md rounded-xl border border-border bg-white"
      style="height: 640px;"
      loading="lazy"
      title="Instagram"
      scrolling="no"
      frameborder="0"
    >
    </iframe>
    """
  end

  def media_embed(%{embed: %{type: :facebook}} = assigns) do
    video? = Map.get(assigns.embed, :fb_video, false)
    assigns = assign(assigns, label: facebook_label(assigns.embed.url), video?: video?)

    # Facebook's plugin iframes are unreliable (blank on localhost, blocked for
    # non-public content) and FB blocks OG scrapers, so a branded card that
    # always renders and links out is the dependable preview.
    ~H"""
    <a
      href={@embed.url}
      target="_blank"
      rel="noopener noreferrer"
      class="flex items-center gap-3 rounded-xl border border-border bg-surface-alt p-3 max-w-xl no-underline hover:border-border-hover transition-colors"
    >
      <span class="flex-shrink-0 w-10 h-10 rounded-lg bg-[#1877F2] flex items-center justify-center">
        <svg viewBox="0 0 24 24" class="w-6 h-6" fill="white" aria-hidden="true">
          <path d="M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073z" />
        </svg>
      </span>
      <span class="min-w-0 flex-1">
        <span class="block text-sm font-semibold text-heading truncate">
          <%= @label %>
        </span>
        <span class="block text-xs text-muted truncate">
          <%= if @video?, do: gettext("Video on Facebook"), else: gettext("View post on Facebook") %>
        </span>
      </span>
      <.icon name="external-link" class="w-4 h-4 text-muted flex-shrink-0" />
    </a>
    """
  end

  # Extract a human label from a Facebook URL (page/profile name when present).
  defp facebook_label(url) when is_binary(url) do
    case Regex.run(~r"facebook\.com/([^/?#]+)/(?:posts|videos|photos)", url) do
      [_, name] when name not in ["watch", "share", "profile.php"] ->
        name |> URI.decode() |> String.replace("-", " ")

      _ ->
        "Facebook"
    end
  end

  def media_embed(%{embed: %{type: :wikipedia}} = assigns) do
    ~H"""
    <a
      href={@embed.url}
      target="_blank"
      rel="noopener noreferrer"
      class="flex items-center gap-3 rounded-xl border border-border bg-surface-alt p-3 max-w-xl no-underline hover:border-border-hover transition-colors"
    >
      <span class="flex-shrink-0 w-10 h-10 rounded-lg bg-white text-black flex items-center justify-center font-serif font-bold text-xl">
        W
      </span>
      <span class="min-w-0 flex-1">
        <span class="block text-sm font-semibold text-heading truncate"><%= @embed.title %></span>
        <span class="block text-xs text-muted truncate">Wikipedia</span>
      </span>
      <span class="text-muted flex-shrink-0"><.icon name="external-link" class="w-4 h-4" /></span>
    </a>
    """
  end

  def media_embed(%{embed: %{type: :twitter}} = assigns) do
    assigns = assign(assigns, :handle, tweet_handle(assigns.embed.url))

    ~H"""
    <div
      id={"tweet-#{:erlang.phash2(@embed.url)}"}
      phx-hook="TwitterEmbed"
      phx-update="ignore"
      class="max-w-xl"
    >
      <%!-- X's widgets.js upgrades this blockquote into the full post. Until then
           (or if it can't load), the styled card below is shown as a fallback. --%>
      <blockquote class="twitter-tweet" data-dnt="true" data-theme="dark">
        <a
          href={@embed.url}
          target="_blank"
          rel="noopener noreferrer"
          class="flex items-center gap-3 rounded-xl border border-border bg-surface-alt p-3 no-underline hover:border-border-hover transition-colors"
        >
          <span class="flex-shrink-0 w-10 h-10 rounded-lg bg-black flex items-center justify-center">
            <svg viewBox="0 0 24 24" class="w-5 h-5" fill="white" aria-hidden="true">
              <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
            </svg>
          </span>
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-semibold text-heading truncate">
              <%= @handle %> <span class="text-muted font-normal">en X</span>
            </span>
            <span class="block text-xs text-muted truncate"><%= gettext("View post on x.com") %></span>
          </span>
        </a>
      </blockquote>
    </div>
    """
  end

  # Detect embeddable URLs directly from the post body — no worker/DB/network.
  # Links inside quotes are skipped: the preview belongs to the original post,
  # not to whoever quoted it (Discourse "onebox" behaviour).
  def body_embeds(body) when is_binary(body) do
    # Allow parentheses in the match (Wikipedia titles like "Racing_Club_(Avellaneda)")
    # then clean trailing punctuation — otherwise the URL is truncated at "(".
    #
    # Sensitive-flagged images are dropped from the scan first: their <img src>
    # URL would otherwise be pulled out as an :image embed and re-rendered as a
    # separate card that carries no data-sensitive flag (so it wouldn't blur),
    # while strip_embed_urls blanks the real inline <img>. Keeping them out lets
    # the flagged <img> render inline and blurred.
    ~r{https?://[^\s"'<>]+}
    |> Regex.scan(body |> strip_blockquotes() |> strip_sensitive_imgs())
    |> List.flatten()
    |> Enum.map(&clean_url/1)
    |> Enum.uniq()
    |> Enum.map(&classify_url/1)
    |> Enum.reject(&(&1 == nil))
    |> Enum.take(3)
  end

  def body_embeds(_), do: []

  @doc """
  Trims trailing punctuation from a URL captured out of prose/HTML.

  Keeps parentheses that belong to the URL (e.g. Wikipedia disambiguation
  titles) but drops a trailing ")" when the URL has no matching "(" — that
  paren belongs to the surrounding sentence, not the link.
  """
  def clean_url(url) do
    url = String.trim_trailing(url, ".")
    url = String.replace(url, ~r/[.,;:!?]+$/, "")

    if String.ends_with?(url, ")") and not String.contains?(url, "(") do
      String.trim_trailing(url, ")")
    else
      url
    end
  end

  # Drop <blockquote>…</blockquote> contents so quoted URLs neither generate
  # previews nor get stripped out of the quote text.
  defp strip_blockquotes(body) do
    String.replace(body, ~r"<blockquote.*?</blockquote>"s, "")
  end

  # Drop sensitive-flagged <img> tags before URL scanning so their src isn't
  # picked up as an image embed (which would render un-blurred). See body_embeds/1.
  defp strip_sensitive_imgs(body) do
    String.replace(body, ~r/<img\b[^>]*\bdata-sensitive\b[^>]*>/i, "")
  end

  # Remove embedded URLs from the body so they aren't shown as text above the embed
  # (Discourse "onebox" behaviour). Handles bare URLs and auto-linked anchors.
  defp strip_embed_urls(body, []) when is_binary(body), do: body

  defp strip_embed_urls(body, urls) when is_binary(body) do
    # Protect quoted content: a quote should keep exactly what was quoted
    # (including its links), so we only strip embed URLs from the poster's own
    # text. The preview card still renders below the post.
    quotes = Regex.scan(~r"<blockquote.*?</blockquote>"s, body) |> List.flatten()

    placeheld =
      quotes
      |> Enum.with_index()
      |> Enum.reduce(body, fn {q, i}, acc -> String.replace(acc, q, "\x00BQ#{i}\x00") end)

    stripped =
      Enum.reduce(urls, placeheld, fn url, acc ->
        esc = Regex.escape(url)

        acc
        |> String.replace(~r"<a[^>]*#{esc}[^>]*>.*?</a>"s, "")
        |> String.replace(url, "")
      end)

    restored =
      quotes
      |> Enum.with_index()
      |> Enum.reduce(stripped, fn {q, i}, acc -> String.replace(acc, "\x00BQ#{i}\x00", q) end)

    # Clean up empty paragraphs left behind.
    String.replace(restored, ~r"<p>\s*</p>"s, "")
  end

  defp strip_embed_urls(body, _urls), do: body

  defp classify_url(url) do
    cond do
      id = youtube_id(url) -> %{type: :youtube, id: id, url: url}
      id = vimeo_id(url) -> %{type: :vimeo, id: id, url: url}
      path = spotify_path(url) -> %{type: :spotify, path: path, url: url}
      soundcloud_url?(url) -> %{type: :soundcloud, url: url}
      id = instagram_id(url) -> %{type: :instagram, id: id, url: url}
      facebook_url?(url) -> %{type: :facebook, url: url, fb_video: facebook_video?(url)}
      # Wikipedia is intentionally NOT matched here — it falls through to the
      # EmbedWorker, which fetches a rich card (thumbnail + summary) via the
      # Wikipedia REST API.
      twitter_url?(url) -> %{type: :twitter, url: normalize_tweet_url(url)}
      media = direct_media(url) -> media
      true -> nil
    end
  end

  # Direct links to image/video files → inline preview (gif / mp4 / webm / png …).
  # `url` is always the original (used to strip it from the post body); `src`
  # is what we actually load — differs only for imgur's .gifv (served as .mp4).
  defp direct_media(url) when is_binary(url) do
    ext = url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.extname() |> String.downcase()

    cond do
      ext in ~w(.jpg .jpeg .png .webp .avif .bmp .apng) -> %{type: :image, url: url}
      ext == ".gif" -> %{type: :image, url: url}
      ext == ".gifv" -> %{type: :video, url: url, src: String.replace_suffix(url, ".gifv", ".mp4"), loop: true}
      ext in ~w(.mp4 .webm .mov .m4v .ogv) -> %{type: :video, url: url}
      true -> nil
    end
  end

  defp direct_media(_), do: nil

  defp instagram_id(url) when is_binary(url) do
    case Regex.run(~r"instagram\.com/(?:p|reel|tv)/([A-Za-z0-9_-]+)", url) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp facebook_url?(url) when is_binary(url),
    do: Regex.match?(~r"https?://(www\.|m\.|web\.)?facebook\.com/[^\s]+/(posts|videos|photos)/", url) or
          Regex.match?(~r"https?://(www\.)?facebook\.com/watch/?\?v=\d+", url) or
          Regex.match?(~r"https?://(www\.)?facebook\.com/share/[pvr]/", url) or
          Regex.match?(~r"https?://fb\.watch/", url)

  # Facebook videos need plugins/video.php; posts/photos use plugins/post.php.
  defp facebook_video?(url) when is_binary(url),
    do: Regex.match?(~r"facebook\.com/[^\s]+/videos/", url) or
          Regex.match?(~r"facebook\.com/watch/?\?v=\d+", url) or
          Regex.match?(~r"facebook\.com/share/v/", url) or
          Regex.match?(~r"fb\.watch/", url)

  # open.spotify.com/track/ID → "track/ID" (also album, playlist, episode, show, artist)
  defp spotify_path(url) when is_binary(url) do
    case Regex.run(~r"open\.spotify\.com/(track|album|playlist|episode|show|artist)/([A-Za-z0-9]+)", url) do
      [_, kind, id] -> "#{kind}/#{id}"
      _ -> nil
    end
  end

  defp soundcloud_url?(url) when is_binary(url),
    do: Regex.match?(~r"https?://(www\.|m\.)?soundcloud\.com/[^/\s]+/[^/\s]+", url)

  defp youtube_id(url) when is_binary(url) do
    cond do
      m = Regex.run(~r"youtube\.com/watch\?v=([A-Za-z0-9_-]{11})", url) -> Enum.at(m, 1)
      m = Regex.run(~r"youtu\.be/([A-Za-z0-9_-]{11})", url) -> Enum.at(m, 1)
      m = Regex.run(~r"youtube\.com/shorts/([A-Za-z0-9_-]{11})", url) -> Enum.at(m, 1)
      true -> nil
    end
  end

  defp youtube_id(_), do: nil

  defp vimeo_id(url) when is_binary(url) do
    case Regex.run(~r"vimeo\.com/(\d+)", url) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp twitter_url?(url) when is_binary(url),
    do: Regex.match?(~r"https?://(www\.)?(twitter|x)\.com/[^/]+/status/\d+", url)

  defp normalize_tweet_url(url), do: url

  defp tweet_handle(url) do
    case Regex.run(~r"(?:twitter|x)\.com/([^/]+)/status", url) do
      [_, handle] -> "@" <> handle
      _ -> "X"
    end
  end

  # Total number of replies in a subtree — direct children plus all their
  # nested descendants (so "3 replies" reflects the whole thread, not just
  # the first level).
  def count_replies(replies) when is_list(replies) do
    Enum.reduce(replies, length(replies), fn reply, acc ->
      acc + count_replies(reply.replies)
    end)
  end

  def count_replies(_), do: 0

  # Flatten the nested post tree into a single list (post + all descendants).
  def flatten_posts(posts) when is_list(posts) do
    Enum.flat_map(posts, fn post -> [post | flatten_posts(post.replies)] end)
  end

  def flatten_posts(_), do: []

  # Total likes/reactions across every post in the topic.
  def total_likes(posts) do
    posts |> flatten_posts() |> Enum.reduce(0, fn p, acc -> acc + (p.reactions_count || 0) end)
  end

  # --- Reply sorting ("Top replies") ----------------------------------------

  # Orders the top-level posts for display. `:top` pins the opening post and
  # ranks the rest by engagement, most first; `:chrono` (default) leaves them
  # in posting order. Nested replies keep their own order in both modes so the
  # threading stays intact.
  def sorted_posts([op | rest], :top) do
    [op | Enum.sort_by(rest, &top_score/1, :desc)]
  end

  def sorted_posts(posts, _sort), do: posts

  # Ranking key for `:top`, compared as a tuple (left to right, highest wins).
  #
  # Reactions alone rank badly in practice: on a real thread only a handful of
  # posts have any, and they nearly all sit at exactly 1 — so the sort became
  # "move a few posts up, leave the rest alone" and read as broken. The extra
  # terms break those ties with signals that already exist on the tree.
  #
  #   1. own reactions      — the post's own score stays dominant, so the
  #                           button keeps meaning what its label says
  #   2. thread reactions   — reactions on descendants: a reply that started a
  #                           busy subthread outranks an equally-liked dead end
  #   3. reply count        — engagement even when nobody reacted
  #
  # Ties fall through to Enum.sort_by's stability, which leaves equal posts in
  # posting order — the chronological order they already had.
  defp top_score(post) do
    {post.reactions_count || 0, thread_reactions(post.replies), count_replies(post.replies)}
  end

  # Total reactions across every descendant of a post (the post itself excluded
  # — that's term 1 above, and it must not be double-counted).
  defp thread_reactions(replies) do
    replies
    |> flatten_posts()
    |> Enum.reduce(0, fn reply, acc -> acc + (reply.reactions_count || 0) end)
  end

  # Distinct participants (users), ordered by their number of posts descending
  # so the most active people show first in the avatar strip.
  def participants(posts) do
    posts
    |> flatten_posts()
    |> Enum.reject(&(&1.is_system || is_nil(&1.user)))
    |> Enum.map(& &1.user)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, users} -> {hd(users), length(users)} end)
    |> Enum.sort_by(fn {_user, count} -> -count end)
    |> Enum.map(fn {user, _count} -> user end)
  end

  # Estimated reading time in minutes (~200 words/min), floored at 1.
  def read_time_minutes(posts) do
    words =
      posts
      |> flatten_posts()
      |> Enum.reduce(0, fn p, acc -> acc + word_count(p.body) end)

    max(div(words, 200) + 1, 1)
  end

  defp word_count(nil), do: 0

  defp word_count(body) when is_binary(body) do
    body
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  # initials/1 and avatar_class/1 now live in CoreComponents so the forum index
  # facepile and the topic page render the same colours for a given user.

  def trust_badge_color(level) do
    case level do
      0 -> "gray"
      1 -> "blue"
      2 -> "green"
      3 -> "purple"
      4 -> "amber"
      _ -> "gray"
    end
  end

  def typing_text(users) when users == [], do: ""

  def typing_text(users) do
    names = Enum.map(users, fn {_id, username} -> username end)

    case names do
      [name] -> gettext("%{name} is typing...", name: name)
      [first, second] -> gettext("%{first} and %{second} are typing...", first: first, second: second)
      [first, second | _rest] -> gettext("%{first}, %{second} and others are typing...", first: first, second: second)
    end
  end

  defp mod_action_message("warn", u), do: gettext("Warning issued to @%{user}.", user: u.username)
  defp mod_action_message("silence", u), do: gettext("@%{user} silenced for 24 hours.", user: u.username)
  defp mod_action_message("suspend", u), do: gettext("@%{user} suspended for 3 days.", user: u.username)
  defp mod_action_message("ban", u), do: gettext("@%{user} banned.", user: u.username)
  defp mod_action_message(_, _), do: gettext("Done.")

  # Human-readable flash for users who are blocked from posting.
  defp moderation_block_message(:silenced),
    do: gettext("You are silenced and cannot post right now.")

  defp moderation_block_message(:suspended),
    do: gettext("Your account is suspended and cannot post.")

  defp moderation_block_message(:banned),
    do: gettext("Your account is banned.")

  defp moderation_block_message(:duplicate_post),
    do: gettext("You just posted that same message. Wait a moment or write something different.")

  def humanize_flag_reason("spam"), do: gettext("Spam")
  def humanize_flag_reason("inappropriate"), do: gettext("Inappropriate")
  def humanize_flag_reason("off_topic"), do: gettext("Off topic")
  def humanize_flag_reason("harassment"), do: gettext("Harassment")
  def humanize_flag_reason("other"), do: gettext("Other")
  def humanize_flag_reason(_), do: gettext("Other")

  # =========================================================================
  # Recursive post renderer
  # =========================================================================

  attr :post, Colloq.Forum.Post, required: true
  attr :topic, Colloq.Forum.Topic, required: true
  attr :current_user, :any, default: nil
  attr :replying_to, :any, default: nil
  attr :nested_reply_body, :string, default: ""
  attr :editing_post, :any, default: nil
  attr :editing_body, :string, default: ""
  attr :reaction_data, :map, default: %{}
  attr :user_reactions, :map, default: %{}
  attr :poll_data, :map, default: nil
  attr :user_votes, :list, default: []
  attr :lineup_data, :map, default: %{}
  attr :bookmarked_posts, :map, default: %{}
  attr :show_flag_for, :any, default: nil
  attr :user_badges, :map, default: %{}
  attr :first_unread_id, :any, default: nil
  attr :blocked_user_ids, :any, default: MapSet.new()
  attr :depth, :integer, default: 0

  # Past this nesting depth we stop indenting (Reddit/HN style) so deep threads
  # don't march off the right edge into a one-character-wide column. Each level
  # only adds a small pad now (the big avatar gutter is top-level only), so we
  # can afford a few more levels before flattening.
  @max_indent_depth 8

  # Reddit-style threading: replies are visible by default and only fold once a
  # branch can't nest any further — "nest until we run out of room, then fold".
  # Deliberately the same number as @max_indent_depth: one concept, so the
  # indent ladder and the fold point can't drift apart.
  @collapse_depth @max_indent_depth

  def post_item(assigns) do
    provider_embeds = body_embeds(assigns.post.body)
    provider_urls = Enum.map(provider_embeds, & &1.url)

    # Generic link previews (newspapers, blogs, …) come from Open Graph data
    # fetched asynchronously by EmbedWorker and stored in the embeds table.
    # Shown whether the URL is quoted or not (quoted links get a preview too).
    body = assigns.post.body || ""

    # Match against the DECODED body. Embed URLs are stored decoded, while the
    # body keeps them HTML-escaped — so a link with a query string lives in the
    # markup as "?a=1&amp;b=2" and never matched "?a=1&b=2". Every URL carrying
    # an ampersand was silently dropped here and rendered without a card.
    # (The quoted/unquoted split below already decoded for this same reason;
    # this filter was missed.)
    decoded_body = Colloq.Workers.EmbedWorker.decode_entities(body)

    og_embeds =
      case assigns.post.embeds do
        list when is_list(list) ->
          list
          |> Enum.reject(&(&1.url in provider_urls))
          |> Enum.filter(&String.contains?(decoded_body, &1.url))
          |> Enum.map(&%{type: :og, url: &1.url, data: &1})

        _ ->
          []
      end

    # Split OG previews by where their URL lives: links inside a quote render
    # their card INSIDE the quote (in place of the URL); links in the poster's
    # own text render as a card below the post (with provider embeds).
    # Compare against the decoded body: embed URLs are stored decoded (a link
    # written "?a=1&b=2" lives in the HTML as "&amp;"), so matching the raw
    # markup would miss every URL containing an ampersand and file it as
    # "quoted" by mistake.
    unquoted = decoded_body |> strip_blockquotes()
    {quoted_og, outer_og} = Enum.split_with(og_embeds, &(not String.contains?(unquoted, &1.url)))
    below_embeds = provider_embeds ++ outer_og

    assigns =
      assign(assigns,
        embeds: below_embeds,
        quoted_cards: quoted_og,
        clean_body: strip_embed_urls(assigns.post.body, Enum.map(below_embeds, & &1.url)),
        indent_replies: assigns.depth < @max_indent_depth,
        collapse_replies: assigns.depth >= @collapse_depth,
        # Only the top-level post gets the big left avatar "gutter". Nested
        # replies (depth > 0) put a small avatar inline in the header and flow
        # full-width, so deep threads don't stack avatar columns off-screen
        # (Reddit/HN behaviour).
        nested: assigns.depth > 0
      )

    ~H"""
    <div
      :if={@first_unread_id && @post.id == @first_unread_id}
      id="unread-divider"
      class="flex items-center gap-3 py-2 scroll-mt-24 text-xs font-semibold uppercase tracking-wide text-accent"
    >
      <span class="h-px flex-1 bg-accent/40"></span>
      <%= gettext("New replies") %>
      <span class="h-px flex-1 bg-accent/40"></span>
    </div>
    <%!-- PostImpression reports the post as seen once it is half on screen.
          The hook and Forum.increment_post_view/1 both already existed but were
          never connected to each other, so every profile read "Views 0". --%>
    <div
      id={"post-#{@post.id}"}
      phx-hook="PostImpression"
      data-post-id={@post.id}
      class="group py-4 border-b border-border last:border-b-0 scroll-mt-24"
    >
      <div class={[!@nested && "flex gap-4"]}>
        <%!-- Big avatar gutter — top-level post only --%>
        <div :if={!@nested} class="flex-shrink-0">
          <div class="relative w-10 h-10">
            <%= if @post.user.avatar_url do %>
              <img src={@post.user.avatar_url} alt="" class="w-10 h-10 rounded-full object-cover" loading="lazy" />
            <% else %>
              <div class={["w-10 h-10 rounded-full flex items-center justify-center font-bold text-white text-sm", avatar_class(@post.user)]}>
                <%= initials(@post.user) %>
              </div>
            <% end %>
            <span
              :if={ColloqWeb.Presence.online?(@post.user.id)}
              class="absolute bottom-0 right-0 w-3 h-3 rounded-full bg-success border-2 border-surface"
              title={gettext("Online")}
            >
            </span>
          </div>
        </div>

        <div class={[!@nested && "flex-1 min-w-0" || "min-w-0"]}>
          <div class="flex items-center gap-2 mb-1 flex-wrap">
            <%!-- Small inline avatar — nested replies only --%>
            <div :if={@nested} class="relative w-6 h-6 flex-shrink-0">
              <%= if @post.user.avatar_url do %>
                <img src={@post.user.avatar_url} alt="" class="w-6 h-6 rounded-full object-cover" loading="lazy" />
              <% else %>
                <div class={["w-6 h-6 rounded-full flex items-center justify-center font-bold text-white text-[10px]", avatar_class(@post.user)]}>
                  <%= initials(@post.user) %>
                </div>
              <% end %>
              <span
                :if={ColloqWeb.Presence.online?(@post.user.id)}
                class="absolute bottom-0 right-0 w-2 h-2 rounded-full bg-success ring-2 ring-surface"
                title={gettext("Online")}
              >
              </span>
            </div>
            <a href={~p"/u/#{@post.user.username}"} class="font-semibold text-heading hover:underline text-sm">
              <%= @post.user.display_name || @post.user.username %>
            </a>
            <.staff_badge role={@post.user.role} show_label={false} />
            <span :if={@post.user.flair} class="text-xs px-1.5 py-0.5 rounded bg-border text-body">
              <%= @post.user.flair %>
            </span>
            <.badge color={trust_badge_color(@post.user.trust_level)}>
              TL<%= @post.user.trust_level %>
            </.badge>
            <span
              :for={badge <- Map.get(@user_badges, @post.user.id, [])}
              class="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 rounded"
              style={"background-color: #{badge.color}20; color: #{badge.color}"}
              title={badge.name}
            >
              <%= badge.icon %>
            </span>
            <span :if={@post.is_system} class="text-xs text-muted ml-auto"><%= gettext("System") %></span>
            <span :if={!@post.is_system} class="text-xs text-muted ml-auto inline-flex items-center gap-1">
              <%!-- Pen marks a post whose body was edited after the grace
                    period. Clicking reveals when — a title tooltip alone is
                    unreachable on touch, where there is no hover. --%>
              <button
                :if={@post.edited_at}
                type="button"
                title={gettext("Edited %{when}", when: es_locale(@post.edited_at))}
                aria-controls={"edited-at-#{@post.id}"}
                aria-expanded="false"
                phx-click={
                  Phoenix.LiveView.JS.toggle(to: "#edited-at-#{@post.id}", display: "inline")
                  |> Phoenix.LiveView.JS.toggle_attribute({"aria-expanded", "true", "false"})
                }
                class="inline-flex items-center text-muted hover:text-heading transition-colors"
              >
                <.icon name="edit" class="w-3 h-3" />
                <span class="sr-only"><%= gettext("Edited") %></span>
              </button>
              <span :if={@post.edited_at} id={"edited-at-#{@post.id}"} class="hidden italic">
                <%= gettext("Edited %{when}", when: es_locale(@post.edited_at)) %>
              </span>
              <%= es_locale(@post.inserted_at) %>
            </span>
          </div>

          <div
            :if={@editing_post != @post.id}
            id={"post-body-#{@post.id}"}
            phx-hook="PostBody"
            data-post-id={@post.id}
            data-quote-label={gettext("Quote")}
            data-quotable={
              @current_user && !@post.is_system && !@topic.closed && !@topic.archived
            }
            class={[
              "prose max-w-none text-sm text-body",
              @post.is_system && "italic text-muted border-l-2 border-border pl-3"
            ]}
          >
            <%= render_post_body(@clean_body, @quoted_cards, @blocked_user_ids) %>
          </div>

          <%!-- Inline edit composer --%>
          <form :if={@editing_post == @post.id} phx-submit="save-edit" class="mt-1">
            <div id={"edit-composer-#{@post.id}"} phx-update="ignore">
              <div
                id={"edit-editor-#{@post.id}"}
                phx-hook="TiptapEditor"
                data-target-input={"edit-input-#{@post.id}"}
                data-placeholder={gettext("Edit your comment…")}
                class="rounded-lg border border-border bg-surface focus-within:border-accent focus-within:ring-2 focus-within:ring-accent"
              >
              </div>
              <input type="hidden" name="body" id={"edit-input-#{@post.id}"} value={@editing_body} />
            </div>
            <div class="flex gap-2 mt-2">
              <.button type="submit" class="text-xs"><%= gettext("Save") %></.button>
              <button type="button" phx-click="cancel-edit" class="text-xs text-muted hover:text-heading transition-colors">
                <%= gettext("Cancel") %>
              </button>
            </div>
          </form>

          <%!-- Live match events (ResultaBot) render as a highlighted inline
                card so a goal is unmistakable while scrolling the thread. --%>
          <.match_event_card
            :if={@post.system_type in ["goal", "card"] && @post.event_data}
            event={@post.event_data}
          />

          <.standings_table :if={@post.system_type == "standings" && @post.event_data} data={@post.event_data} />

          <%!-- Player comparison: reuses the generic SVG-in-event_data renderer. --%>
          <.standings_table :if={@post.system_type == "comparison" && @post.event_data} data={@post.event_data} />

          <%!-- Single-player season card: same generic SVG renderer. --%>
          <.standings_table :if={@post.system_type == "player_card" && @post.event_data} data={@post.event_data} />

          <.poll_display
            :if={@poll_data}
            poll_data={@poll_data}
            user_votes={@user_votes}
            current_user={@current_user}
          />

          <%!-- "The XI I'd play" board attached to this post --%>
          <.lineup_display
            :if={Map.get(@lineup_data, @post.id)}
            lineup={Map.get(@lineup_data, @post.id)}
          />

          <%!-- Rich embeds detected from the post body (YouTube, Vimeo, X) --%>
          <div :for={emb <- @embeds} class="mt-3">
            <.media_embed embed={emb} />
          </div>

          <div :if={!@post.is_system} class="flex items-center flex-wrap gap-x-4 gap-y-2 mt-3">
            <.reaction_bar
              post_id={@post.id}
              reactions={Map.get(@reaction_data, @post.id, %{}) |> Enum.map(fn {emoji, count} -> %{emoji: emoji, count: count} end)}
              user_reactions={Map.get(@user_reactions, @post.id)}
              can_react={@current_user && @current_user.id != @post.user_id}
            />

            <div :if={@current_user && !@topic.closed && !@topic.archived} class="flex items-center gap-3">
              <button
              type="button"
              phx-click="start-nested-reply"
              phx-value-post_id={@post.id}
              class="inline-flex items-center gap-1 text-xs text-muted hover:text-heading transition-colors"
            >
              <.icon name="reply" class="w-3.5 h-3.5" /><%= gettext("Reply") %>
            </button>
            <button
              :if={!@post.is_system}
              type="button"
              phx-click="quote-post"
              phx-value-post_id={@post.id}
              class="inline-flex items-center gap-1 text-xs text-muted hover:text-heading transition-colors"
            >
              <.icon name="quote" class="w-3.5 h-3.5" /><%= gettext("Quote") %>
            </button>
            <button
              type="button"
              phx-click="show-flag"
              phx-value-post_id={@post.id}
              class="inline-flex items-center gap-1 text-xs text-muted hover:text-danger transition-colors"
            >
              <.icon name="flag" class="w-3.5 h-3.5" /><%= gettext("Report") %>
            </button>
            <button
              :if={can_edit_post?(@current_user, @post, @topic)}
              type="button"
              phx-click="start-edit"
              phx-value-post_id={@post.id}
              class="inline-flex items-center gap-1 text-xs text-muted hover:text-heading transition-colors"
            >
              <.icon name="edit" class="w-3.5 h-3.5" /><%= gettext("Edit") %>
            </button>
            <button
              :if={@post.user_id == @current_user.id || Colloq.Permissions.can?(@current_user, :hide_posts)}
              type="button"
              phx-click="delete-post"
              phx-value-post_id={@post.id}
              data-confirm={gettext("Delete this comment? This can't be undone.")}
              class="inline-flex items-center gap-1 text-xs text-muted hover:text-danger transition-colors"
            >
              <.icon name="trash-2" class="w-3.5 h-3.5" /><%= gettext("Delete") %>
            </button>

            <%!-- Moderator menu: sanctions against the post author --%>
            <div
              :if={@current_user && Colloq.Permissions.can?(@current_user, :warn_users) && @post.user_id != @current_user.id && !@post.is_system && Colloq.Permissions.can_moderate?(@current_user, @post.user)}
              class="relative"
              id={"mod-menu-#{@post.id}"}
            >
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.toggle(to: "#mod-dropdown-#{@post.id}")}
                class="inline-flex items-center gap-1 text-xs text-muted hover:text-heading transition-colors"
              >
                <.icon name="shield" class="w-3.5 h-3.5" /><%= gettext("Mod") %>
              </button>
              <div
                id={"mod-dropdown-#{@post.id}"}
                phx-click-away={Phoenix.LiveView.JS.hide()}
                class="hidden absolute bottom-full right-0 mb-1 bg-surface border border-border rounded-lg shadow-lg py-1 min-w-[180px] z-10"
              >
                <button
                  type="button"
                  phx-click={
                    Phoenix.LiveView.JS.push("open-warn")
                    |> Phoenix.LiveView.JS.hide(to: "#mod-dropdown-#{@post.id}")
                  }
                  phx-value-user_id={@post.user_id}
                  phx-value-username={@post.user.username}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-warning-soft hover:text-warning transition-colors"
                >
                  <.icon name="alert-triangle" class="w-3.5 h-3.5 text-warning" /><%= gettext("Warn author") %>
                </button>
                <button
                  :if={Colloq.Permissions.can?(@current_user, :silence_users)}
                  type="button"
                  phx-click="mod-action"
                  phx-value-action="silence"
                  phx-value-user_id={@post.user_id}
                  data-confirm={gettext("Silence this user for 24 hours? They can read but not post.")}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-accent-soft hover:text-accent transition-colors"
                >
                  <.icon name="mic-off" class="w-3.5 h-3.5 text-accent" /><%= gettext("Silence 24h") %>
                </button>
                <button
                  :if={Colloq.Permissions.can?(@current_user, :suspend_users)}
                  type="button"
                  phx-click="mod-action"
                  phx-value-action="suspend"
                  phx-value-user_id={@post.user_id}
                  data-confirm={gettext("Suspend this user for 3 days? They can't log in.")}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-orange-soft hover:text-orange transition-colors"
                >
                  <.icon name="clock" class="w-3.5 h-3.5 text-orange" /><%= gettext("Suspend 3d") %>
                </button>
                <button
                  :if={Colloq.Permissions.can?(@current_user, :ban_users)}
                  type="button"
                  phx-click="mod-action"
                  phx-value-action="ban"
                  phx-value-user_id={@post.user_id}
                  data-confirm={gettext("Ban this user permanently?")}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-danger-soft hover:text-danger transition-colors"
                >
                  <.icon name="ban" class="w-3.5 h-3.5 text-danger" /><%= gettext("Ban") %>
                </button>
              </div>
            </div>
            </div>

            <%!-- Share is a sibling of the reply-actions block, not a child:
                  linking to a post has nothing to do with being able to reply
                  to it, so it stays available to logged-out readers and on
                  closed/archived topics, where that block renders nothing. --%>
            <div class="relative flex items-center" id={"share-menu-#{@post.id}"}>
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.toggle(to: "#share-dropdown-#{@post.id}")}
                class="inline-flex items-center gap-1 text-xs text-muted hover:text-heading transition-colors"
              >
                <.icon name="share-2" class="w-3.5 h-3.5" /><%= gettext("Share") %>
              </button>
              <div
                id={"share-dropdown-#{@post.id}"}
                phx-click-away={Phoenix.LiveView.JS.hide()}
                class="hidden absolute bottom-full left-0 mb-1 bg-surface border border-border rounded-lg shadow-lg py-1 min-w-[160px] z-10"
              >
                <button
                  type="button"
                  phx-click={
                    Phoenix.LiveView.JS.push("copy-link", value: %{post_id: @post.id})
                    |> Phoenix.LiveView.JS.hide(to: "#share-dropdown-#{@post.id}")
                  }
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="copy" class="w-3.5 h-3.5" /><%= gettext("Copy link") %>
                </button>
                <a
                  href={share_url("https://wa.me/", text: "Mirá este post: " <> post_url(@topic.id, @post.id))}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center gap-2 px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="message-circle" class="w-3.5 h-3.5" /> WhatsApp
                </a>
                <a
                  href={
                    share_url("https://twitter.com/intent/tweet",
                      url: post_url(@topic.id, @post.id),
                      text: @topic.title
                    )
                  }
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center gap-2 px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="external-link" class="w-3.5 h-3.5" /> X / Twitter
                </a>
                <a
                  href={
                    share_url("https://t.me/share/url",
                      url: post_url(@topic.id, @post.id),
                      text: @topic.title
                    )
                  }
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex items-center gap-2 px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="send" class="w-3.5 h-3.5" /> Telegram
                </a>
              </div>
            </div>
          </div>

          <%!-- Flag form --%>
          <div :if={@show_flag_for == @post.id} class="mt-3 p-3 rounded-lg bg-danger-soft border border-danger-border">
            <p class="text-xs text-muted mb-2"><%= gettext("Why are you reporting this?") %></p>
            <div class="flex flex-wrap gap-1.5">
              <button
                :for={reason <- ~w(spam inappropriate off_topic harassment other)}
                type="button"
                phx-click="flag-post"
                phx-value-post_id={@post.id}
                phx-value-reason={reason}
                class="px-2 py-1 text-xs rounded bg-bg border border-border text-body hover:border-danger hover:text-danger transition-colors"
              >
                <%= humanize_flag_reason(reason) %>
              </button>
            </div>
            <button type="button" phx-click="hide-flag" class="text-xs text-muted hover:text-body mt-2"><%= gettext("Cancel") %></button>
          </div>

          <div :if={@replying_to == @post.id} class="mt-3">
            <form phx-submit="submit-nested-reply">
              <div id={"nested-composer-#{@post.id}"} phx-update="ignore">
                <div
                  id={"nested-reply-editor-#{@post.id}"}
                  phx-hook="TiptapEditor"
                  data-target-input={"nested-reply-input-#{@post.id}"}
                  data-placeholder={gettext("Write here. Use the toolbar or Markdown to format.")}
                  class="rounded-lg border border-border bg-surface focus-within:border-accent focus-within:ring-2 focus-within:ring-accent"
                >
                </div>
                <input type="hidden" name="body" id={"nested-reply-input-#{@post.id}"} />
              </div>
              <div class="flex gap-2 mt-2">
                <.button type="submit" class="text-xs"><%= gettext("Post reply") %></.button>
                <button type="button" phx-click="cancel-nested-reply" class="text-xs text-muted hover:text-heading transition-colors">
                  <%= gettext("Cancel") %>
                </button>
              </div>
            </form>
          </div>

          <div :if={@post.replies != []} class="mt-2">
            <button
              type="button"
              phx-click={
                Phoenix.LiveView.JS.toggle(to: "#replies-#{@post.id}")
                |> Phoenix.LiveView.JS.toggle_class("rotate-90", to: "#replies-chevron-#{@post.id}")
              }
              class="inline-flex items-center gap-1 text-xs font-semibold text-accent hover:text-accent-hover transition-colors"
            >
              <span
                id={"replies-chevron-#{@post.id}"}
                class={["transition-transform", !@collapse_replies && "rotate-90"]}
              >▸</span>
              <%= count_replies(@post.replies) %>
              <%= if count_replies(@post.replies) == 1, do: gettext("reply"), else: gettext("replies") %>
            </button>
            <%!-- Visible by default; only branches deeper than @collapse_depth
                 start collapsed. The toggle above works either way. --%>
            <div id={"replies-#{@post.id}"} class={[
              "mt-2 border-l-2",
              @collapse_replies && "hidden",
              @indent_replies && "pl-3 border-border" || "pl-2 border-accent-border"
            ]}>
              <%= for reply <- @post.replies do %>
                <.post_item
                  post={reply}
                  topic={@topic}
                  first_unread_id={@first_unread_id}
                  current_user={@current_user}
                  replying_to={@replying_to}
                  nested_reply_body={@nested_reply_body}
                  editing_post={@editing_post}
                  editing_body={@editing_body}
                  reaction_data={@reaction_data}
                  user_reactions={@user_reactions}
                  poll_data={@poll_data}
                  user_votes={@user_votes}
                  lineup_data={@lineup_data}
                  bookmarked_posts={@bookmarked_posts}
                  show_flag_for={@show_flag_for}
                  user_badges={@user_badges}
                  blocked_user_ids={@blocked_user_ids}
                  depth={@depth + 1}
                />
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # =========================================================================
  # Poll display component
  # =========================================================================

  attr :lineup, :any, required: true

  @doc """
  Renders a post's starting XI. Drawn here rather than inside the post body
  because the body scrubber strips `style` (so a positioned board can't survive
  there) — same reason polls render as a component.
  """
  def lineup_display(assigns) do
    lineup = assigns.lineup

    # Positions come from the formation; the players are the frozen snapshot.
    pairs = Enum.zip(Colloq.Lineups.layout(lineup.formation), lineup.players)

    assigns =
      assigns
      |> assign(:pairs, pairs)
      |> assign(:team_name, team_name(lineup.team_id))
      |> assign(:colors, Colloq.Sofascore.team_colors(lineup.team_id))

    ~H"""
    <div class="mt-4 rounded-xl border border-border bg-surface overflow-hidden max-w-sm">
      <div class="flex items-center justify-between px-3 py-2 border-b border-border">
        <span class="text-sm font-semibold text-heading"><%= @team_name %></span>
        <span class="rounded-md bg-accent px-2 py-0.5 text-[10px] font-semibold text-white">
          <%= @lineup.formation %>
        </span>
      </div>

      <div
        class="relative"
        style="aspect-ratio: 3 / 4; background: repeating-linear-gradient(0deg, #2d8a4e 0px, #2d8a4e 32px, #2a814a 32px, #2a814a 64px);"
      >
        <div class="absolute inset-2 border-2 border-white/20 rounded-sm"></div>
        <div class="absolute left-2 right-2 top-1/2 h-0.5 -translate-y-px bg-white/20"></div>
        <div class="absolute left-1/2 top-1/2 h-20 w-20 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white/20"></div>
        <div class="absolute left-1/2 top-2 h-12 w-32 -translate-x-1/2 border-2 border-t-0 border-white/20"></div>
        <div class="absolute left-1/2 bottom-2 h-12 w-32 -translate-x-1/2 border-2 border-b-0 border-white/20"></div>

        <div
          :for={{slot, player} <- @pairs}
          class="absolute flex w-16 -translate-x-1/2 -translate-y-1/2 flex-col items-center gap-0.5"
          style={"left: #{slot.x}%; top: #{slot.y}%;"}
        >
          <.jersey
            primary={@colors.primary}
            secondary={@colors.secondary}
            gk={slot.role == :gk}
            class="w-7 h-6 drop-shadow"
          />
          <span class="text-[9px] font-bold leading-tight text-white text-center drop-shadow whitespace-nowrap">
            <%= short_label(player["name"]) %>
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp team_name(team_id) do
    case Colloq.Sofascore.team_key_by_id(team_id) do
      nil -> "Equipo #{team_id}"
      key -> Colloq.Sofascore.team_info(key).name
    end
  end

  defp short_label(name) when is_binary(name) and name != "" do
    name |> String.split() |> List.last() |> String.upcase()
  end

  defp short_label(_), do: "—"

  attr :poll_data, :map, required: true
  attr :user_votes, :list, default: []
  attr :current_user, :any, default: nil

  def poll_display(assigns) do
    poll = assigns.poll_data.poll
    has_voted = assigns.user_votes != []

    assigns =
      assigns
      |> assign(:poll, poll)
      |> assign(:has_voted, has_voted)

    ~H"""
    <div class="mt-4 p-4 rounded-lg bg-surface-alt border border-border">
      <div class="flex items-center gap-2 mb-3">
        <span class="text-accent">📊</span>
        <h4 class="text-sm font-semibold text-heading"><%= @poll.question %></h4>
        <span :if={@poll.anonymous} class="text-xs text-muted ml-auto inline-flex items-center gap-1">
          <.icon name="eye-off" class="w-3 h-3" /><%= gettext("Anonymous") %>
        </span>
        <span :if={@poll.closed} class={["text-xs text-muted", !@poll.anonymous && "ml-auto"]}>
          <%= gettext("Closed") %>
        </span>
      </div>

      <div :if={@has_voted || @poll.closed} id={"poll-#{@poll.id}"} class="space-y-3">
        <div class="flex justify-end -mb-1">
          <button
            type="button"
            phx-click={
              Phoenix.LiveView.JS.toggle_class("hidden", to: "#poll-#{@poll.id} .poll-pct")
              |> Phoenix.LiveView.JS.toggle_class("hidden", to: "#poll-#{@poll.id} .poll-count")
            }
            class="inline-flex items-center gap-1 text-xs text-muted hover:text-heading transition-colors"
            title={gettext("Switch between votes and percentage")}
          >
            <.icon name="refresh-cw" class="w-3 h-3" /> #/%
          </button>
        </div>
        <%= for option <- @poll_data.options do %>
          <div class="relative">
            <div class="flex items-center justify-between mb-1">
              <span class="text-sm text-body"><%= option.text %></span>
              <span class="text-xs text-muted tabular-nums">
                <span class="poll-pct"><%= option.percentage %>%</span>
                <span class="poll-count hidden">
                  <%= option.votes %> <%= ngettext("vote", "votes", option.votes) %>
                </span>
              </span>
            </div>
            <div class="h-2 bg-border rounded-full overflow-hidden">
              <div
                class="h-full bg-accent rounded-full transition-all duration-300"
                style={"width: #{option.percentage}%"}
              />
            </div>
            <div :if={!@poll.anonymous && option.voters != []} class="flex items-center flex-wrap gap-1 mt-1.5">
              <a
                :for={voter <- Enum.take(option.voters, 12)}
                href={~p"/u/#{voter.username}"}
                class="inline-flex"
                title={voter.display_name || voter.username}
              >
                <img
                  :if={voter.avatar_url}
                  src={voter.avatar_url}
                  alt=""
                  class="w-5 h-5 rounded-full object-cover ring-1 ring-border"
                  loading="lazy"
                />
                <span
                  :if={!voter.avatar_url}
                  class={[
                    "w-5 h-5 rounded-full flex items-center justify-center font-bold text-white text-[9px]",
                    avatar_class(voter)
                  ]}
                >
                  <%= initials(voter) %>
                </span>
              </a>
              <span :if={length(option.voters) > 12} class="text-xs text-muted self-center">
                +<%= length(option.voters) - 12 %>
              </span>
            </div>
          </div>
        <% end %>
        <p class="text-xs text-muted mt-2"><%= @poll_data.total_votes %> <%= gettext("votes") %></p>
      </div>

      <div :if={!@has_voted && !@poll.closed && @current_user} class="space-y-2">
        <%= for option <- @poll_data.options do %>
          <button
            type="button"
            phx-click="vote-poll"
            phx-value-poll_id={@poll.id}
            phx-value-option_id={option.id}
            class="w-full text-left px-3 py-2 rounded-lg bg-bg border border-border text-sm text-body hover:border-accent hover:text-heading transition-colors"
          >
            <%= option.text %>
          </button>
        <% end %>
      </div>

      <p :if={!@current_user && !@poll.closed} class="text-xs text-muted mt-2">
        <a href="/login" class="text-accent hover:text-accent-hover"><%= gettext("Log in") %></a> <%= gettext("to vote.") %>
      </p>
    </div>
    """
  end

  @doc """
  Human text for a `topics.closed_reason` code.

  The column stores internal codes set by the system ("duplicate" when a
  re-post is auto-closed, "post_limit" at the 50k cap); moderators may also
  type a free-form reason, which is shown as-is.
  """
  def closed_reason_text("duplicate"),
    do: gettext("it duplicates a topic you already had open.")

  def closed_reason_text("post_limit"),
    do: gettext("it reached the maximum number of comments. Continue in a new topic.")

  def closed_reason_text(reason), do: "#{reason}."

end
