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
      conversations = Messaging.list_conversations(current_user.id)

      socket =
        socket
        |> assign(:current_user, current_user)
        |> assign(:conversations, conversations)
        |> assign(:active_conversation, nil)
        |> assign(:messages, [])
        |> assign(:message_body, "")
        |> assign(:page_title, "Mensajes")

      {:ok, socket}
    else
      {:ok, push_redirect(socket, to: "/login")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    conversation_id = String.to_integer(id)
    conversation = Messaging.get_conversation!(conversation_id)

    if socket.assigns.current_user.id in [conversation.user1_id, conversation.user2_id] do
      if connected?(socket) do
        ColloqWeb.Endpoint.subscribe("dm:#{conversation_id}")
      end

      Messaging.mark_read!(conversation_id, socket.assigns.current_user.id)

      {:noreply,
       socket
       |> assign(:active_conversation, conversation)
       |> assign(:messages, conversation.messages)
       |> assign(:page_title, other_user(conversation, socket.assigns.current_user).display_name || other_user(conversation, socket.assigns.current_user).username)}
    else
      {:noreply, put_flash(socket, :error, "No tenés acceso a esta conversación.")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :active_conversation, nil)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messages/#{id}")}
  end

  def handle_event("send", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.active_conversation

    if body != "" && conv do
      case Messaging.send_message(conv.id, user, body) do
        {:ok, _message} ->
          {:noreply, assign(socket, :message_body, "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo enviar el mensaje.")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(%{event: "new_message", payload: payload}, socket) do
    new_message = %{
      id: System.unique_integer([:monotonic]),
      body: payload.body,
      user_id: payload.sender_id,
      inserted_at: payload.timestamp,
      read: false
    }

    messages = socket.assigns.messages ++ [new_message]

    {:noreply, assign(socket, :messages, messages)}
  end

  def other_user(conversation, current_user) do
    if conversation.user1_id == current_user.id do
      conversation.user2
    else
      conversation.user1
    end
  end

  def last_message_preview(conversation) do
    if conversation.last_message do
      String.slice(conversation.last_message.body, 0..60)
    else
      "Sin mensajes"
    end
  end
end
