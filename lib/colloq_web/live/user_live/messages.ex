defmodule ColloqWeb.UserLive.Messages do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Messaging
  alias Colloq.Messaging.Message

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case session["user_id"] do
        nil -> nil
        user_id -> Accounts.get_user!(user_id)
      end

    if current_user do
      blocked_ids = Accounts.dm_blocked_user_ids(current_user.id)
      conversations = Messaging.list_conversations(current_user.id)

      # Subscribed for the whole page rather than per thread: the sidebar used
      # to refresh only inside the "dm:<id>" handler, so a message arriving in
      # any thread you didn't have open left the list stale.
      if connected?(socket), do: ColloqWeb.Endpoint.subscribe("dm_list:#{current_user.id}")

      socket =
        socket
        |> assign(:current_user, current_user)
        |> assign(:conversations, conversations)
        |> assign(:unread_counts, Messaging.unread_counts(current_user.id))
        |> assign(:active_conversation, nil)
        |> assign(:messages, [])
        |> assign(:has_more_messages, false)
        # The message being quoted by the composer, if any.
        |> assign(:replying_to, nil)
        |> assign(:replying_to_id, nil)
        |> assign(:message_body, "")
        # Topic this LiveView is currently subscribed to, so we can drop it
        # before subscribing to another (see subscribe_to_conversation/2).
        |> assign(:subscribed_topic, nil)
        |> assign(:blocked_user_ids, blocked_ids)
        # Corrected by the ChatFocus hook on connect; assumed true so a client
        # with JS disabled behaves as it always did.
        |> assign(:window_focused, true)
        |> assign(:page_title, gettext("Messages"))
        |> assign(:show_new_conversation, false)
        |> assign(:user_query, "")
        |> assign(:user_results, [])

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: "/login")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    conversation_id = String.to_integer(id)

    case Messaging.get_conversation(conversation_id) do
      nil ->
        {:noreply,
         socket
         |> assign(:active_conversation, nil)
         |> put_flash(:error, gettext("This conversation no longer exists."))
         |> push_patch(to: ~p"/messages")}

      conversation ->
        handle_conversation(conversation, conversation_id, socket)
    end
  end

  defp handle_conversation(conversation, conversation_id, socket) do
    me = socket.assigns.current_user

    if me.id in [conversation.user1_id, conversation.user2_id] do
      show_conversation(conversation, conversation_id, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have access to this conversation."))}
    end
  end

  # `handle_params` runs on every patch — including re-selecting a chat you've
  # already visited — and Phoenix.PubSub delivers one copy of each broadcast
  # PER subscribe call. Without dropping the previous subscription, opening
  # A → B → A leaves you subscribed to A twice and every message renders twice.
  defp subscribe_to_conversation(socket, conversation_id) do
    topic = "dm:#{conversation_id}"

    cond do
      not connected?(socket) ->
        socket

      socket.assigns[:subscribed_topic] == topic ->
        socket

      true ->
        if prev = socket.assigns[:subscribed_topic] do
          ColloqWeb.Endpoint.unsubscribe(prev)
        end

        ColloqWeb.Endpoint.subscribe(topic)
        assign(socket, :subscribed_topic, topic)
    end
  end

  defp show_conversation(conversation, conversation_id, socket) do
    if socket.assigns.current_user.id in [conversation.user1_id, conversation.user2_id] do
      other = other_user(conversation, socket.assigns.current_user)

      if other.id in socket.assigns.blocked_user_ids do
        {:noreply,
         socket
         |> put_flash(:error, "Este usuario está bloqueado.")
         |> redirect(to: "/messages")}
      else
        socket = subscribe_to_conversation(socket, conversation_id)

        Messaging.mark_read!(conversation_id, socket.assigns.current_user.id)

        user_id = socket.assigns.current_user.id
        messages = Messaging.list_messages(conversation.id, user_id)

        {:noreply,
         socket
         |> assign(:active_conversation, conversation)
         |> assign(:messages, messages)
         # Switching threads drops a half-composed reply; the quoted message
         # belongs to the conversation you just left.
         |> assign(:replying_to, nil)
         |> assign(:replying_to_id, nil)
         |> assign(
           :has_more_messages,
           Messaging.more_messages?(conversation.id, user_id, oldest_cursor(messages))
         )
         |> assign(:unread_messages, Messaging.unread_count(user_id))
         |> assign(:unread_counts, Messaging.unread_counts(user_id))
         |> assign(:page_title, other.display_name || other.username)}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have access to this conversation."))}
    end
  end

  # Back to the list: drop the subscription too, or messages from the chat we
  # just left would keep appending to a conversation that's no longer open.
  def handle_params(_params, _uri, socket) do
    if topic = socket.assigns[:subscribed_topic] do
      ColloqWeb.Endpoint.unsubscribe(topic)
    end

    {:noreply,
     socket
     |> assign(:active_conversation, nil)
     |> assign(:subscribed_topic, nil)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages/#{id}")}
  end

  # Window focus, reported by the ChatFocus hook. Coming back to a tab that
  # collected messages while you were away is the moment they count as read.
  def handle_event("window-focus", %{"focused" => focused}, socket) do
    socket = assign(socket, :window_focused, focused)
    conv = socket.assigns.active_conversation

    if focused && conv do
      Messaging.mark_read!(conv.id, socket.assigns.current_user.id)
      {:noreply, refresh_sidebar(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_body", %{"body" => body}, socket) do
    {:noreply, assign(socket, :message_body, body)}
  end

  # Block or ignore the other participant straight from the conversation, so
  # an unsolicited chat can be shut down without hunting for their profile.
  def handle_event("block-conversation", %{"mode" => mode}, socket) do
    me = socket.assigns.current_user
    conv = socket.assigns.active_conversation
    mode = if mode == "ignore", do: "ignore", else: "block"

    if conv do
      other = other_user(conv, me)

      case Accounts.block_user(me.id, other.id, mode) do
        {:ok, _} ->
          msg =
            if mode == "ignore",
              do: gettext("User ignored. You won't see their posts."),
              else: gettext("User blocked. Neither of you will be able to message the other.")

          {:noreply,
           socket
           |> assign(:blocked_user_ids, Accounts.dm_blocked_user_ids(me.id))
           |> put_flash(:info, msg)}

        {:error, :cannot_block_staff} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("You can't block staff. You can ignore them to hide their posts.")
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  # Older history, one page at a time, triggered by the sentinel at the top of
  # the thread. Replies (rather than :noreply) so the client can restore the
  # scroll position once the prepended page has been patched in.
  def handle_event("load-older", _params, socket) do
    conv = socket.assigns.active_conversation
    user = socket.assigns.current_user
    cursor = oldest_cursor(socket.assigns.messages)

    if conv && cursor do
      older = Messaging.list_messages(conv.id, user.id, before: cursor)
      messages = older ++ socket.assigns.messages

      {:reply, %{},
       socket
       |> assign(:messages, messages)
       |> assign(
         :has_more_messages,
         Messaging.more_messages?(conv.id, user.id, oldest_cursor(messages))
       )}
    else
      {:reply, %{}, assign(socket, :has_more_messages, false)}
    end
  end

  # Quote a message in the composer.
  def handle_event("reply-to", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {message_id, _} ->
        case Enum.find(socket.assigns.messages, &(&1.id == message_id)) do
          nil -> {:noreply, socket}
          message -> {:noreply, assign(socket, replying_to: message, replying_to_id: message.id)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel-reply", _params, socket) do
    {:noreply, assign(socket, replying_to: nil, replying_to_id: nil)}
  end

  # Delete one of your own messages (soft-delete).
  def handle_event("delete-message", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    case Integer.parse(to_string(id)) do
      {message_id, _} when not is_nil(conv) ->
        case Messaging.delete_message(message_id, user) do
          {:ok, _} ->
            # Drop it from the window in place. Re-listing would throw away every
            # older page the reader had already scrolled back through.
            {:noreply,
             assign(
               socket,
               :messages,
               Enum.reject(socket.assigns.messages, &(&1.id == message_id))
             )}

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # "Delete for me": hide a conversation from your list. Works both from the
  # in-thread menu and the sidebar (which passes an explicit id).
  def handle_event("delete-conversation", params, socket) do
    me = socket.assigns.current_user
    active = socket.assigns.active_conversation

    id =
      case params["id"] do
        nil -> active && active.id
        v -> String.to_integer(v)
      end

    if id do
      Messaging.delete_conversation(id, me)
      deleting_active? = active && active.id == id

      socket =
        socket
        |> refresh_sidebar()
        |> put_flash(:info, gettext("Conversation deleted."))

      socket =
        if deleting_active? do
          socket
          |> assign(:active_conversation, nil)
          |> assign(:messages, [])
          |> push_patch(to: ~p"/messages")
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("mark-conversation-read", %{"id" => id}, socket) do
    me = socket.assigns.current_user
    conversation_id = String.to_integer(id)

    conv = Messaging.get_conversation(conversation_id)

    # Only for a conversation you're actually a participant in.
    if conv && me.id in [conv.user1_id, conv.user2_id] do
      Messaging.mark_read!(conversation_id, me.id)

      {:noreply, refresh_sidebar(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("unblock-conversation", _params, socket) do
    me = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    if conv do
      other = other_user(conv, me)
      Accounts.unblock_user(me.id, other.id)

      {:noreply,
       socket
       |> assign(:blocked_user_ids, Accounts.dm_blocked_user_ids(me.id))
       |> put_flash(:info, gettext("User unblocked."))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open-new-conversation", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_conversation, true)
     |> assign(:user_query, "")
     |> assign(:user_results, [])}
  end

  def handle_event("close-new-conversation", _params, socket) do
    {:noreply, assign(socket, :show_new_conversation, false)}
  end

  def handle_event("search-users", %{"q" => query}, socket) do
    results =
      query
      |> Accounts.search_users_for_mention(8)
      |> Enum.reject(&(&1.username == socket.assigns.current_user.username))

    {:noreply,
     socket
     |> assign(:user_query, query)
     |> assign(:user_results, results)}
  end

  def handle_event("start-conversation", %{"username" => username}, socket) do
    me = socket.assigns.current_user

    case Accounts.get_user_by_username(username) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("User not found."))}

      %{id: id} when id == me.id ->
        {:noreply, socket}

      other ->
        case Messaging.can_message?(me, other) do
          :ok ->
            case Messaging.find_or_create_conversation(me.id, other.id) do
              {:ok, conversation} ->
                {:noreply,
                 socket
                 |> assign(:show_new_conversation, false)
                 |> assign(:conversations, Messaging.list_conversations(me.id))
                 |> push_patch(to: ~p"/messages/#{conversation.id}")}

              {:error, _} ->
                {:noreply,
                 put_flash(socket, :error, gettext("Could not start the conversation."))}
            end

          {:error, :opted_out} ->
            {:noreply, put_flash(socket, :error, gettext("This user isn't accepting messages."))}

          {:error, :blocked} ->
            {:noreply, put_flash(socket, :error, gettext("You can't message this user."))}
        end
    end
  end

  def handle_event("send", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.active_conversation
    body = String.trim(body)

    if body != "" && conv do
      other = other_user(conv, user)

      case Messaging.can_message?(user, other) do
        :ok ->
          case Messaging.send_message(conv.id, user, body, socket.assigns.replying_to_id) do
            {:ok, _message} ->
              {:noreply,
               socket
               |> assign(:message_body, "")
               |> assign(:replying_to, nil)
               |> assign(:replying_to_id, nil)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, gettext("Could not send the message."))}
          end

        {:error, :opted_out} ->
          {:noreply, put_flash(socket, :error, gettext("This user isn't accepting messages."))}

        {:error, :blocked} ->
          {:noreply, put_flash(socket, :error, gettext("You can't message this user."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send-sticker", %{"url" => url}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    if conv && Colloq.Stickers.sticker_url?(url) &&
         Messaging.can_message?(user, other_user(conv, user)) == :ok do
      Messaging.send_sticker(conv.id, user, url)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_message", payload: payload}, socket) do
    me = socket.assigns.current_user

    # The row is loaded rather than rebuilt from the payload, so the appended
    # bubble carries its real id and its quoted parent.
    message =
      if payload.sender_id in socket.assigns.blocked_user_ids,
        do: nil,
        else: Messaging.get_message_for_display(payload.message_id)

    if is_nil(message) do
      {:noreply, socket}
    else
      messages = socket.assigns.messages ++ [message]

      # Read means *seen*: only mark it if the reader is actually looking at the
      # window. Marking on arrival regardless of focus meant a message landing
      # in an open-but-unfocused tab was read before anyone saw it — no unread
      # badge, no count in the tab title, no notification-worthy state at all,
      # which is exactly the case you hit testing with two windows open.
      conv = socket.assigns.active_conversation

      if conv && payload.sender_id != me.id && socket.assigns.window_focused,
        do: Messaging.mark_read!(conv.id, me.id)

      {:noreply,
       socket
       |> assign(:messages, messages)
       |> refresh_sidebar()}
    end
  end

  # A link preview finished fetching. Only the one bubble is swapped — reloading
  # the thread would throw away every older page the reader had scrolled back
  # through, and the message may not be in the loaded window at all.
  def handle_info(%{event: "embed_ready", payload: %{message_id: message_id}}, socket) do
    if Enum.any?(socket.assigns.messages, &(&1.id == message_id)) do
      case Messaging.get_message_for_display(message_id) do
        nil ->
          {:noreply, socket}

        fresh ->
          messages =
            Enum.map(socket.assigns.messages, &if(&1.id == message_id, do: fresh, else: &1))

          {:noreply, assign(socket, :messages, messages)}
      end
    else
      {:noreply, socket}
    end
  end

  # A message landed in one of my conversations. Only the sidebar and the badge
  # are touched: if that thread is also open, the "dm:<id>" handler above is
  # what appends the bubble, and doing it here too would double it.
  def handle_info(%{event: "conversations_changed"}, socket) do
    {:noreply, refresh_sidebar(socket)}
  end

  # The other participant opened the conversation and read our messages — flip
  # our own bubbles to "read" so their double check turns blue in real time.
  def handle_info(%{event: "read", payload: %{reader_id: reader_id}}, socket) do
    me = socket.assigns.current_user

    if reader_id == me.id do
      {:noreply, socket}
    else
      messages =
        Enum.map(socket.assigns.messages, fn m ->
          if m.user_id == me.id and not m.read, do: %{m | read: true}, else: m
        end)

      {:noreply, assign(socket, :messages, messages)}
    end
  end

  # Sidebar state travels together: the row order, each row's unread badge and
  # the header badge all come from the same three queries, so refreshing one
  # without the others is what leaves a stale count on screen.
  defp refresh_sidebar(socket) do
    me = socket.assigns.current_user

    socket
    |> assign(:conversations, Messaging.list_conversations(me.id))
    |> assign(:unread_counts, Messaging.unread_counts(me.id))
    |> assign(:unread_messages, Messaging.unread_count(me.id))
  end

  def other_user(conversation, current_user) do
    if conversation.user1_id == current_user.id do
      conversation.user2
    else
      conversation.user1
    end
  end

  @doc """
  Hover actions for a message bubble: reply, plus delete on your own.

  Rendered on whichever side of the bubble faces the middle of the pane —
  before it for your own right-aligned messages, after it for theirs. The reply
  arrow is mirrored to match, so it always points at the bubble it acts on
  rather than off toward the edge.
  """
  attr :row, :map, required: true

  def msg_actions(assigns) do
    ~H"""
    <div class="relative flex items-center gap-0.5 opacity-0 group-hover:opacity-100 focus-within:opacity-100 transition-opacity flex-shrink-0">
      <button
        type="button"
        phx-click="reply-to"
        phx-value-id={@row.msg.id}
        title={gettext("Reply")}
        class="p-1 rounded text-muted hover:text-heading transition-colors"
      >
        <.icon name="reply" class={["w-4 h-4", @row.mine && "scale-x-[-1]"]} />
      </button>
      <button
        :if={@row.mine}
        type="button"
        phx-click="delete-message"
        phx-value-id={@row.msg.id}
        data-confirm={gettext("Delete this message?")}
        title={gettext("Delete")}
        class="p-1 rounded text-muted hover:text-danger transition-colors"
      >
        <.icon name="trash-2" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  # Paging cursor: the oldest persisted message on screen.
  defp oldest_cursor(messages), do: Enum.find(messages, &match?(%Message{}, &1))

  @doc """
  The message quoted by `msg`, `:deleted` if it's gone, or nil if this isn't a
  reply. A quoted message can vanish two ways — soft-deleted by its author, or
  hard-deleted by the prune path, which nilifies `reply_to_id`'s target — and
  both render the same placeholder.
  """
  def quoted(%{reply_to_id: nil}), do: nil
  def quoted(%{reply_to: %Message{deleted_at: nil} = parent}), do: parent
  def quoted(%{reply_to: %Message{}}), do: :deleted
  def quoted(%{reply_to: nil}), do: :deleted
  def quoted(_), do: nil

  @doc "Name to show above a quoted message."
  def quote_author(%Message{user_id: uid}, %{id: uid}), do: gettext("You")

  def quote_author(%Message{} = parent, _current_user) do
    # Matching the struct specifically, not `%{}` — `Ecto.Association.NotLoaded`
    # is itself a map, so a loose pattern let an unloaded association through
    # and blew up on the field access.
    case parent.user do
      %Colloq.Accounts.User{} = user -> user.display_name || user.username
      _ -> gettext("Message")
    end
  end

  @doc "A sticker message renders as a bare floating image, not a bubble."
  def sticker?(%{sticker_url: url}) when is_binary(url) and url != "", do: true

  def sticker?(_), do: false

  @doc """
  A Lottie/TGS sticker is vector JSON, not an image, so it can't go in an
  `<img>` — it's mounted by the LottieSticker hook instead.
  """
  def lottie_sticker?(%{sticker_url: url} = msg) when is_binary(url) do
    sticker?(msg) and (String.ends_with?(url, ".tgs") or String.ends_with?(url, ".json"))
  end

  def lottie_sticker?(_), do: false

  @doc """
  Renders a chat message body as rich text: media URLs (images, GIFs, YouTube,
  etc.) are pulled out and rendered as cards below the bubble via
  `message_embeds/1`, remaining links are auto-linked, and `:shortcodes:` become
  custom-emoji images.

  Chat bodies are plain text, so we escape *first* and inject markup after — a
  user typing raw HTML can't spoof link/emoji markup. The auto-linked URL is
  taken from already-escaped text, so it can't contain a `"` to break out of the
  href attribute. Emoji names/URLs are validated when the emoji is created.
  """
  def render_body(body) when is_binary(body) do
    urls = body |> message_embeds() |> Enum.map(& &1.url)

    urls
    |> Enum.reduce(body, fn url, acc -> String.replace(acc, url, "") end)
    |> String.trim()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> autolink()
    |> Colloq.Emojis.render_shortcodes()
    |> Phoenix.HTML.raw()
  end

  def render_body(_), do: Phoenix.HTML.raw("")

  @doc """
  Telegram-style delivery receipt shown on the sender's own bubbles: a single
  check once sent, a blue double check once the recipient has read it.
  """
  attr :read, :boolean, default: false

  attr :variant, :atom,
    default: :accent,
    doc: ":accent (on the accent bubble) or :muted (on a light badge)"

  def read_receipt(assigns) do
    assigns =
      assign(
        assigns,
        :color,
        cond do
          assigns.read and assigns.variant == :accent -> "text-sky-300"
          assigns.read -> "text-sky-500"
          assigns.variant == :accent -> "text-white/50"
          true -> "text-muted"
        end
      )

    ~H"""
    <span class={["inline-flex flex-shrink-0", @color]} title={(@read && gettext("Read")) || gettext("Sent")}>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor"
           stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <%= if @read do %>
          <path d="M18 6 7 17l-5-5" />
          <path d="m22 10-7.5 7.5L13 16" />
        <% else %>
          <path d="M20 6 9 17l-5-5" />
        <% end %>
      </svg>
    </span>
    """
  end

  @doc """
  Media embeds for a chat message — images, GIFs, video and provider URLs
  (YouTube, Vimeo, Spotify, …) — reusing the same synchronous detection as forum
  posts. Generic Open Graph link cards (fetched asynchronously for posts) are
  intentionally excluded; those URLs stay as plain auto-links.
  """
  def message_embeds(%{body: body}), do: message_embeds(body)
  def message_embeds(body) when is_binary(body), do: ColloqWeb.ForumLive.Topic.body_embeds(body)
  def message_embeds(_), do: []

  @doc """
  Open Graph cards attached to a message (at most one), or `[]`.

  Returns a list so the template can iterate without a nil check, and tolerates
  an unloaded association — a bubble appended straight from a broadcast can
  reach the template before its embeds have been preloaded.
  """
  def link_previews(%{embeds: embeds}) when is_list(embeds), do: embeds
  def link_previews(_), do: []

  @doc """
  Whether a message still has visible text once its media URLs are stripped out.
  A message that was *only* a link/image renders as the embed alone (no empty
  text line).
  """
  def has_text?(%{body: body}) when is_binary(body) do
    urls = body |> message_embeds() |> Enum.map(& &1.url)
    stripped = Enum.reduce(urls, body, fn url, acc -> String.replace(acc, url, "") end)
    String.trim(stripped) != ""
  end

  def has_text?(_), do: false

  @emoji_only ~r/^(?:\s|\p{So}|\p{Sk}|[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{200D}\x{20E3}\x{1F1E6}-\x{1F1FF}])+$/u

  @doc """
  Whether a message is *only* emoji (up to 8) and has no sticker/embed — those
  render large and bubble-less, WhatsApp/Telegram-style.
  """
  def emoji_only?(%{sticker_url: url}) when is_binary(url) and url != "", do: false

  def emoji_only?(%{body: body} = msg) when is_binary(body) do
    t = String.trim(body)

    t != "" and String.length(t) <= 8 and message_embeds(msg) == [] and
      Regex.match?(@emoji_only, t)
  end

  def emoji_only?(_), do: false

  # Wrap bare http(s) URLs in a link. Runs on already-escaped text.
  defp autolink(text) do
    Regex.replace(
      ~r{(?<!["'=>])(https?://[^\s<>"']+)},
      text,
      ~s(<a href="\\1" target="_blank" rel="noopener noreferrer" class="underline break-all">\\1</a>)
    )
  end

  @doc """
  Annotates messages with grouping flags for a Telegram-style thread:
    - `mine`      — sent by the current user
    - `top`       — first of a run of consecutive same-sender messages (more spacing)
    - `tail`      — last of the run (rounded "tail" corner + timestamp)
    - `day_break` — label to render *above* this message when it opens a new
      day, else nil. Bubbles only carry a clock time, so without these the
      thread gives no way to tell an hour's gap from a fortnight's.
  """
  def message_rows(messages, current_user_id) do
    list = Enum.to_list(messages)

    list
    |> Enum.with_index()
    |> Enum.map(fn {m, i} ->
      prev = if i > 0, do: Enum.at(list, i - 1), else: nil
      next = Enum.at(list, i + 1)

      %{
        msg: m,
        mine: m.user_id == current_user_id,
        top: is_nil(prev) or prev.user_id != m.user_id,
        tail: is_nil(next) or next.user_id != m.user_id,
        day_break: day_break(prev, m)
      }
    end)
  end

  # The oldest message on screen always gets a separator — with pagination it's
  # the top of the loaded window, not necessarily the start of the thread.
  defp day_break(nil, msg), do: day_label(msg.inserted_at)

  defp day_break(prev, msg) do
    unless same_day?(prev.inserted_at, msg.inserted_at), do: day_label(msg.inserted_at)
  end

  defp same_day?(a, b), do: local_date(a) == local_date(b)

  defp local_date(datetime), do: datetime |> to_display_tz() |> DateTime.to_date()

  defp day_label(datetime) do
    date = local_date(datetime)
    today = local_date(DateTime.utc_now())

    cond do
      date == today -> gettext("Today")
      date == Date.add(today, -1) -> gettext("Yesterday")
      date.year == today.year -> es_short_date(datetime)
      true -> es_date(datetime)
    end
  end

  @doc """
  Clock time for a bubble.

  Only the time — the day comes from the separator above it. The shared
  `es_locale/1` collapses anything older than a month to a bare "14d", which
  told the reader nothing about when a message was actually sent.
  """
  def chat_time(datetime), do: datetime |> to_display_tz() |> Calendar.strftime("%H:%M")

  def online?(user_id), do: ColloqWeb.Presence.online?(user_id)

  @doc """
  One-line preview for the conversation list.
  """
  def last_message_preview(conversation) do
    case conversation.last_message do
      nil -> gettext("No messages")
      msg -> message_preview(msg)
    end
  end

  @doc """
  One-line plain-text summary of a message — used by the sidebar and by the
  quoted-reply strip.

  A body that is nothing but a media URL renders in-thread as an embed, so
  previewing it verbatim spilled a raw https://… across the row. Those are
  described by kind instead.
  """
  def message_preview(msg, max \\ 60) do
    cond do
      sticker?(msg) ->
        "🏷 " <> gettext("Sticker")

      has_text?(msg) ->
        msg.body |> String.trim() |> ellipsize(max)

      true ->
        case message_embeds(msg) do
          [%{type: type} | _] -> media_preview(type)
          [] -> gettext("No messages")
        end
    end
  end

  @doc """
  Shorter preview for the quoted strip inside a bubble.

  The strip is one narrow line, so the sidebar's 60 characters were always cut
  off by CSS mid-word with no ellipsis to show it had been.
  """
  def quote_preview(msg), do: message_preview(msg, 42)

  # Cut on the last word boundary that fits rather than mid-word, and say so.
  defp ellipsize(text, max) do
    if String.length(text) <= max do
      text
    else
      text
      |> String.slice(0, max)
      |> String.replace(~r/\s+\S*$/u, "")
      |> Kernel.<>("…")
    end
  end

  defp media_preview(:image), do: "🖼 " <> gettext("Image")
  defp media_preview(:video), do: "🎬 " <> gettext("Video")
  defp media_preview(_), do: "🔗 " <> gettext("Link")
end
