defmodule ColloqWeb.UserLive.Messages do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Messaging

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case session["user_id"] do
        nil -> nil
        user_id -> Accounts.get_user!(user_id)
      end

    if current_user do
      blocked_ids = Accounts.blocked_user_ids(current_user.id)
      conversations = Messaging.list_conversations(current_user.id)

      socket =
        socket
        |> assign(:current_user, current_user)
        |> assign(:conversations, conversations)
        |> assign(:active_conversation, nil)
        |> assign(:messages, [])
        |> assign(:message_body, "")
        |> assign(:blocked_user_ids, blocked_ids)
        |> assign(:page_title, gettext("Messages"))
        |> assign(:show_new_conversation, false)
        |> assign(:user_query, "")
        |> assign(:user_results, [])

      {:ok, socket}
    else
      {:ok, push_redirect(socket, to: "/login")}
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
      {:noreply, put_flash(socket, :error, gettext("You don't have access to this conversation."))}
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
        if connected?(socket) do
          ColloqWeb.Endpoint.subscribe("dm:#{conversation_id}")
        end

        Messaging.mark_read!(conversation_id, socket.assigns.current_user.id)

        {:noreply,
         socket
         |> assign(:active_conversation, conversation)
         |> assign(:messages, Messaging.list_messages(conversation.id, socket.assigns.current_user.id))
         |> assign(:unread_messages, Messaging.unread_count(socket.assigns.current_user.id))
         |> assign(:page_title, other.display_name || other.username)}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("You don't have access to this conversation."))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :active_conversation, nil)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages/#{id}")}
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
           |> assign(:blocked_user_ids, Accounts.blocked_user_ids(me.id))
           |> put_flash(:info, msg)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Action failed."))}
      end
    else
      {:noreply, socket}
    end
  end

  # Delete one of your own messages (soft-delete).
  def handle_event("delete-message", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    case Integer.parse(to_string(id)) do
      {message_id, _} when not is_nil(conv) ->
        case Messaging.delete_message(message_id, user) do
          {:ok, _} ->
            {:noreply, assign(socket, :messages, Messaging.list_messages(conv.id, user.id))}

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
        |> assign(:conversations, Messaging.list_conversations(me.id))
        |> assign(:unread_messages, Messaging.unread_count(me.id))
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

  def handle_event("unblock-conversation", _params, socket) do
    me = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    if conv do
      other = other_user(conv, me)
      Accounts.unblock_user(me.id, other.id)

      {:noreply,
       socket
       |> assign(:blocked_user_ids, Accounts.blocked_user_ids(me.id))
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
                {:noreply, put_flash(socket, :error, gettext("Could not start the conversation."))}
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
          case Messaging.send_message(conv.id, user, body) do
            {:ok, _message} ->
              {:noreply, assign(socket, :message_body, "")}

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

  def handle_event("send-file", %{"url" => url} = params, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    if conv && Messaging.can_message?(user, other_user(conv, user)) == :ok do
      Messaging.send_attachment(conv.id, user, %{
        url: url,
        name: params["name"],
        type: params["type"]
      })
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_message", payload: payload}, socket) do
    if payload.sender_id in socket.assigns.blocked_user_ids do
      {:noreply, socket}
    else
      new_message = %{
        id: System.unique_integer([:monotonic]),
        body: payload.body,
        user_id: payload.sender_id,
        inserted_at: payload.timestamp,
        read: false,
        attachment_url: Map.get(payload, :attachment_url),
        attachment_name: Map.get(payload, :attachment_name),
        attachment_type: Map.get(payload, :attachment_type)
      }

      messages = socket.assigns.messages ++ [new_message]
      me = socket.assigns.current_user

      # Since the recipient is looking at this conversation, mark it read so the
      # header badge doesn't over-count.
      conv = socket.assigns.active_conversation
      if conv && payload.sender_id != me.id, do: Messaging.mark_read!(conv.id, me.id)

      {:noreply,
       socket
       |> assign(:messages, messages)
       |> assign(:conversations, Messaging.list_conversations(me.id))
       |> assign(:unread_messages, Messaging.unread_count(me.id))}
    end
  end

  def other_user(conversation, current_user) do
    if conversation.user1_id == current_user.id do
      conversation.user2
    else
      conversation.user1
    end
  end

  def attachment_image?(%{attachment_url: url, attachment_type: type})
      when is_binary(url) and url != "" do
    String.starts_with?(type || "", "image/")
  end

  def attachment_image?(_), do: false

  @doc """
  Annotates messages with grouping flags for a Telegram-style thread:
    - `mine`  — sent by the current user
    - `top`   — first of a run of consecutive same-sender messages (more spacing)
    - `tail`  — last of the run (rounded "tail" corner + timestamp)
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
        tail: is_nil(next) or next.user_id != m.user_id
      }
    end)
  end

  def online?(user_id), do: ColloqWeb.Presence.online?(user_id)

  def last_message_preview(conversation) do
    case conversation.last_message do
      nil ->
        gettext("No messages")

      %{body: body} when is_binary(body) and body != "" ->
        String.slice(body, 0..60)

      %{attachment_name: name} when is_binary(name) ->
        "📎 " <> name

      _ ->
        "📎 " <> gettext("Attachment")
    end
  end
end
