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

  alias Colloq.Forum
  alias Colloq.Repo
  alias Colloq.Accounts
  alias Colloq.Reactions
  alias Colloq.Tags

  @typing_timeout 5_000

  @impl true
  def mount(%{"id" => id}, session, socket) do
    current_user = load_user(session)
    blocked_ids = if current_user, do: Accounts.hidden_user_ids(current_user.id), else: MapSet.new()
    topic = Forum.get_topic!(id, blocked_ids)

    # Set up all assigns with sensible defaults.
    # UI-only state (form visibility, replying_to, poll form) is initialised
    # to empty/false so the template renders cleanly on first paint.
    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:topic, topic)
      |> assign(:posts, topic.posts)
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
      # Match mode flag inherited from the topic (e.g. live-match vs static)
      |> assign(:match_mode, topic.match_mode)
      # AI-generated summary (nil until generated or loaded from cache)
      |> assign(:summary, nil)
      |> assign(:summary_at, nil)
      |> assign(:summary_loading, false)
      # Inline poll creation form state
      |> assign(:show_poll_form, false)
      |> assign(:poll_question, "")
      |> assign(:poll_options, ["", ""])
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
        |> load_reaction_data(topic.posts)
        |> load_user_reactions(topic.posts, current_user)
        |> load_cached_summary(topic.id)
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

  # Quote a comment: insert a blockquote (with attribution) into the main
  # reply composer.
  def handle_event("quote-post", %{"post_id" => post_id}, socket) do
    if socket.assigns.current_user do
      post = Forum.get_post!(String.to_integer(post_id))
      html = quote_html(post)

      {:noreply, push_event(socket, "tiptap:quote", %{target: "reply-editor", html: html})}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  def handle_event("submit-nested-reply", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic
    parent_id = socket.assigns.replying_to

    if user && parent_id && !topic.closed && !topic.archived do
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

        {:error, reason} when reason in [:silenced, :suspended, :banned] ->
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

    if user && !topic.closed && !topic.archived do
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

        {:error, reason} when reason in [:silenced, :suspended, :banned] ->
          {:noreply, put_flash(socket, :error, moderation_block_message(reason))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not post the reply."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You cannot reply to this topic."))}
    end
  end

  def handle_event("start-edit-topic", _params, socket) do
    if can_edit_topic?(socket.assigns.current_user, socket.assigns.topic) do
      {:noreply,
       socket
       |> assign(:editing_topic, true)
       |> assign(:edit_title, socket.assigns.topic.title)
       |> assign(:edit_category_id, socket.assigns.topic.category_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-edit-topic", _params, socket) do
    {:noreply, assign(socket, :editing_topic, false)}
  end

  def handle_event("save-edit-topic", %{"title" => title} = params, socket) do
    topic = socket.assigns.topic

    if can_edit_topic?(socket.assigns.current_user, topic) do
      attrs = %{"title" => title, "category_id" => params["category_id"]}

      case Forum.update_topic(topic, attrs) do
        {:ok, _} ->
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

    if user && (post.user_id == user.id || Colloq.Permissions.can?(user, :hide_posts)) do
      {:noreply, assign(socket, editing_post: post_id, editing_body: post.body || "")}
    else
      {:noreply, socket}
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

      post.user_id == user.id or Colloq.Permissions.can?(user, :hide_posts) ->
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
        {:ok, _} = Forum.delete_post(post)
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
      Reactions.toggle_reaction(post_id, user.id, emoji)

      user_reactions =
        Map.put(
          socket.assigns.user_reactions,
          post_id,
          Reactions.user_reactions(post_id, user.id)
        )

      {:noreply, assign(socket, :user_reactions, user_reactions)}
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

  # Inline moderator actions on a post's author (warn / silence / suspend / ban).
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

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You don't have permission for this action."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Action failed."))}
    end
  end

  # Share event
  def handle_event("copy-link", %{"post_id" => post_id}, socket) do
    url = "#{ColloqWeb.Endpoint.url()}/t/#{socket.assigns.topic.id}#post-#{post_id}"
    push_event(socket, "copy-to-clipboard", %{text: url})

    {:noreply, put_flash(socket, :info, gettext("Link copied!"))}
  end

  # AI summary: enqueue an Oban job that will broadcast "summary_ready"
  # when done. The result is cached in Cachex so subsequent mounts are fast.
  def handle_event("generate-summary", _params, socket) do
    if socket.assigns.current_user do
      %{user_id: socket.assigns.current_user.id, topic_id: socket.assigns.topic.id}
      |> Colloq.Workers.TopicSummarizerWorker.new()
      |> Oban.insert()

      {:noreply, assign(socket, :summary_loading, true)}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  # Poll events — these manage the inline poll creation form and voting.
  # Polls are attached to a post: the form is toggled open/closed, options
  # can be added/removed (min 2, max 10), and submitted together with the
  # post body. Voting is one-vote-per-user per poll.
  def handle_event("toggle-poll-form", _params, socket) do
    {:noreply, assign(socket, :show_poll_form, !socket.assigns.show_poll_form)}
  end

  def handle_event("update-poll-question", %{"value" => question}, socket) do
    {:noreply, assign(socket, :poll_question, question)}
  end

  def handle_event("update-poll-option", %{"index" => idx, "value" => value}, socket) do
    options = List.replace_at(socket.assigns.poll_options, String.to_integer(idx), value)
    {:noreply, assign(socket, :poll_options, options)}
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
            Forum.create_poll(post, question, options)

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
           |> load_reaction_data(topic.posts)
           |> load_user_reactions(topic.posts, user)
           |> load_poll_data(topic.posts, user)}

        {:error, reason} when reason in [:silenced, :suspended, :banned] ->
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
  # PubSub: a new post was created by another client — reload the topic
  # tree (including nested replies) and refresh reaction data.
  def handle_info(%{event: "new_post", payload: _payload}, socket) do
    topic = Forum.get_topic!(socket.assigns.topic.id, socket.assigns.blocked_user_ids)
    user = socket.assigns.current_user

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

  def handle_info(%{event: "reaction_updated", payload: %{post_id: post_id, counts: counts}}, socket) do
    {:noreply,
     socket
     |> assign(:reaction_data, Map.put(socket.assigns.reaction_data, post_id, counts))}
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

  # PubSub: the Oban summarizer job finished — load the summary into assigns.
  def handle_info(%{event: "summary_ready", payload: payload}, socket) do
    {:noreply,
     socket
     |> assign(:summary, payload.summary)
     |> assign(:summary_at, Map.get(payload, :generated_at))
     |> assign(:summary_loading, false)}
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  defp load_cached_summary(socket, topic_id) do
    case Cachex.get(:forum_cache, "summary:#{topic_id}") do
      {:ok, %{summary: summary, generated_at: at}} ->
        socket |> assign(:summary, summary) |> assign(:summary_at, at)

      {:ok, summary} when is_binary(summary) ->
        assign(socket, :summary, summary)

      _ ->
        socket
    end
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
    assigns.current_user && !assigns.topic.closed && !assigns.topic.archived
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
    |> Phoenix.HTML.raw()
  end

  # Build the HTML inserted into the composer when quoting a comment.
  defp quote_html(post) do
    # Use the real username as the handle so it links to the right profile
    # (display names aren't valid @mentions).
    handle = if post.user, do: post.user.username, else: gettext("someone")

    text =
      (post.body || "")
      |> HtmlSanitizeEx.strip_tags()
      |> String.trim()
      |> String.slice(0, 800)
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    label = Phoenix.HTML.html_escape("@#{handle}:") |> Phoenix.HTML.safe_to_string()

    "<blockquote><p><strong>#{label}</strong> #{text}</p></blockquote><p></p>"
  end

  # Turn bare http(s) URLs into clickable links (skips ones already in an attribute/tag).
  defp autolink(text) do
    Regex.replace(
      ~r{(?<!["'=>])(https?://[^\s<>"']+)},
      text,
      ~s(<a href="\\1" target="_blank" rel="noopener noreferrer">\\1</a>)
    )
  end

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
    ~r{https?://[^\s"'<>]+}
    |> Regex.scan(strip_blockquotes(body))
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

  # Remove embedded URLs from the body so they aren't shown as text above the embed
  # (Discourse "onebox" behaviour). Handles bare URLs and auto-linked anchors.
  defp strip_embed_urls(body, []) when is_binary(body), do: body

  defp strip_embed_urls(body, urls) when is_binary(body) do
    stripped =
      Enum.reduce(urls, body, fn url, acc ->
        esc = Regex.escape(url)

        acc
        |> String.replace(~r"<a[^>]*#{esc}[^>]*>.*?</a>"s, "")
        |> String.replace(url, "")
      end)

    # Clean up empty paragraphs left behind.
    String.replace(stripped, ~r"<p>\s*</p>"s, "")
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

  def initials(user) do
    name = user.display_name || user.username
    String.slice(name, 0..0) |> String.upcase()
  end

  def avatar_class(user) do
    colors = %{
      blue: "bg-blue-600",
      green: "bg-green-600",
      red: "bg-red-600",
      amber: "bg-amber-600",
      purple: "bg-purple-600"
    }

    idx = :erlang.phash2(user.id, map_size(colors))
    colors |> Map.values() |> Enum.at(idx)
  end

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
  attr :bookmarked_posts, :map, default: %{}
  attr :show_flag_for, :any, default: nil
  attr :user_badges, :map, default: %{}
  attr :depth, :integer, default: 0

  # Past this nesting depth we stop indenting (Reddit/HN style) so deep threads
  # don't march off the right edge into a one-character-wide column. Each level
  # only adds a small pad now (the big avatar gutter is top-level only), so we
  # can afford a few more levels before flattening.
  @max_indent_depth 8

  def post_item(assigns) do
    provider_embeds = body_embeds(assigns.post.body)
    provider_urls = Enum.map(provider_embeds, & &1.url)

    # Generic link previews (newspapers, blogs, …) come from Open Graph data
    # fetched asynchronously by EmbedWorker and stored in the embeds table.
    # Only show a card if its URL still appears outside any quote — this also
    # hides cards stored before quoted links were excluded.
    unquoted_body = strip_blockquotes(assigns.post.body || "")

    og_embeds =
      case assigns.post.embeds do
        list when is_list(list) ->
          list
          |> Enum.reject(&(&1.url in provider_urls))
          |> Enum.filter(&String.contains?(unquoted_body, &1.url))
          |> Enum.map(&%{type: :og, url: &1.url, data: &1})

        _ ->
          []
      end

    all_embeds = provider_embeds ++ og_embeds

    assigns =
      assign(assigns,
        embeds: all_embeds,
        clean_body: strip_embed_urls(assigns.post.body, Enum.map(all_embeds, & &1.url)),
        indent_replies: assigns.depth < @max_indent_depth,
        # Only the top-level post gets the big left avatar "gutter". Nested
        # replies (depth > 0) put a small avatar inline in the header and flow
        # full-width, so deep threads don't stack avatar columns off-screen
        # (Reddit/HN behaviour).
        nested: assigns.depth > 0
      )

    ~H"""
    <div id={"post-#{@post.id}"} class="group py-4 border-b border-border last:border-b-0">
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
            <span :if={!@post.is_system} class="text-xs text-muted ml-auto">
              <%= es_locale(@post.inserted_at) %>
            </span>
          </div>

          <div
            :if={@editing_post != @post.id}
            class={[
              "prose max-w-none text-sm text-body",
              @post.is_system && "italic text-muted border-l-2 border-border pl-3"
            ]}
          >
            <%= render_body(@clean_body) %>
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

          <.goal_alert :if={@post.system_type == "goal" && @post.event_data}
            player={@post.event_data[:player] || @post.event_data["player"] || gettext("Player")}
            minute={@post.event_data[:minute] || @post.event_data["minute"] || 0}
          />

          <.poll_display
            :if={@poll_data}
            poll_data={@poll_data}
            user_votes={@user_votes}
            current_user={@current_user}
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
            <div class="relative" id={"share-menu-#{@post.id}"}>
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
                  phx-click="copy-link"
                  phx-value-post_id={@post.id}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="copy" class="w-3.5 h-3.5" /><%= gettext("Copy link") %>
                </button>
                <a
                  href={"https://wa.me/?text=#{URI.encode("Mira este post: " <> ColloqWeb.Endpoint.url() <> "/t/" <> to_string(@topic.id) <> "#post-" <> to_string(@post.id))}"}
                  target="_blank"
                  class="flex items-center gap-2 px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="message-circle" class="w-3.5 h-3.5" /> WhatsApp
                </a>
                <a
                  href={"https://twitter.com/intent/tweet?url=#{URI.encode(ColloqWeb.Endpoint.url() <> "/t/" <> to_string(@topic.id) <> "#post-" <> to_string(@post.id))}&text=#{URI.encode(@topic.title)}"}
                  target="_blank"
                  class="flex items-center gap-2 px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="external-link" class="w-3.5 h-3.5" /> X / Twitter
                </a>
                <a
                  href={"https://t.me/share/url?url=#{URI.encode(ColloqWeb.Endpoint.url() <> "/t/" <> to_string(@topic.id) <> "#post-" <> to_string(@post.id))}&text=#{URI.encode(@topic.title)}"}
                  target="_blank"
                  class="flex items-center gap-2 px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="send" class="w-3.5 h-3.5" /> Telegram
                </a>
              </div>
            </div>
            <button
              :if={@post.user_id == @current_user.id || Colloq.Permissions.can?(@current_user, :hide_posts)}
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
              :if={@current_user && Colloq.Permissions.can?(@current_user, :warn_users) && @post.user_id != @current_user.id && !@post.is_system}
              class="relative"
              id={"mod-menu-#{@post.id}"}
            >
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.toggle(to: "#mod-dropdown-#{@post.id}")}
                class="inline-flex items-center gap-1 text-xs text-muted hover:text-danger transition-colors"
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
                  phx-click="mod-action"
                  phx-value-action="warn"
                  phx-value-user_id={@post.user_id}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="alert-triangle" class="w-3.5 h-3.5" /><%= gettext("Warn author") %>
                </button>
                <button
                  :if={Colloq.Permissions.can?(@current_user, :silence_users)}
                  type="button"
                  phx-click="mod-action"
                  phx-value-action="silence"
                  phx-value-user_id={@post.user_id}
                  data-confirm={gettext("Silence this user for 24 hours? They can read but not post.")}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="mic-off" class="w-3.5 h-3.5" /><%= gettext("Silence 24h") %>
                </button>
                <button
                  :if={Colloq.Permissions.can?(@current_user, :suspend_users)}
                  type="button"
                  phx-click="mod-action"
                  phx-value-action="suspend"
                  phx-value-user_id={@post.user_id}
                  data-confirm={gettext("Suspend this user for 3 days? They can't log in.")}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-body hover:bg-border transition-colors"
                >
                  <.icon name="clock" class="w-3.5 h-3.5" /><%= gettext("Suspend 3d") %>
                </button>
                <button
                  :if={Colloq.Permissions.can?(@current_user, :ban_users)}
                  type="button"
                  phx-click="mod-action"
                  phx-value-action="ban"
                  phx-value-user_id={@post.user_id}
                  data-confirm={gettext("Ban this user permanently?")}
                  class="flex items-center gap-2 w-full text-left px-3 py-1.5 text-xs text-danger hover:bg-danger-soft transition-colors"
                >
                  <.icon name="ban" class="w-3.5 h-3.5" /><%= gettext("Ban") %>
                </button>
              </div>
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
              <span id={"replies-chevron-#{@post.id}"} class="rotate-90 transition-transform">▸</span>
              <%= count_replies(@post.replies) %>
              <%= if count_replies(@post.replies) == 1, do: gettext("reply"), else: gettext("replies") %>
            </button>
            <div id={"replies-#{@post.id}"} class={[
              "mt-2 border-l-2",
              @indent_replies && "pl-3 border-border" || "pl-2 border-accent-border"
            ]}>
              <%= for reply <- @post.replies do %>
                <.post_item
                  post={reply}
                  topic={@topic}
                  current_user={@current_user}
                  replying_to={@replying_to}
                  nested_reply_body={@nested_reply_body}
                  editing_post={@editing_post}
                  editing_body={@editing_body}
                  reaction_data={@reaction_data}
                  user_reactions={@user_reactions}
                  poll_data={@poll_data}
                  user_votes={@user_votes}
                  bookmarked_posts={@bookmarked_posts}
                  show_flag_for={@show_flag_for}
                  user_badges={@user_badges}
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
        <span :if={@poll.closed} class="text-xs text-muted ml-auto"><%= gettext("Closed") %></span>
      </div>

      <div :if={@has_voted || @poll.closed} class="space-y-2">
        <%= for option <- @poll_data.options do %>
          <div class="relative">
            <div class="flex items-center justify-between mb-1">
              <span class="text-sm text-body"><%= option.text %></span>
              <span class="text-xs text-muted"><%= option.votes %> (<%= option.percentage %>%)</span>
            </div>
            <div class="h-2 bg-border rounded-full overflow-hidden">
              <div
                class="h-full bg-accent rounded-full transition-all duration-300"
                style={"width: #{option.percentage}%"}
              />
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
end
