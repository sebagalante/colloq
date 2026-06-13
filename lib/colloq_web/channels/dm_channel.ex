defmodule ColloqWeb.DmChannel do
  use Phoenix.Channel

  alias Colloq.Messaging

  def join("dm:" <> conversation_id, _payload, socket) do
    conv = Messaging.get_conversation!(conversation_id)

    if socket.assigns.user_id in [conv.user1_id, conv.user2_id] do
      {:ok, assign(socket, :conversation_id, conversation_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("new_message", %{"body" => body}, socket) do
    conversation_id = socket.assigns.conversation_id
    user = socket.assigns.current_user

    case Messaging.send_message(conversation_id, user, body) do
      {:ok, message} ->
        payload = %{
          sender_id: user.id,
          body: message.body,
          timestamp: message.inserted_at
        }

        ColloqWeb.Endpoint.broadcast("dm:#{conversation_id}", "new_message", payload)
        {:noreply, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "failed_to_send"}}, socket}
    end
  end
end
