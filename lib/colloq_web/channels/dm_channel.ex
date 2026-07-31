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
      {:ok, _message} ->
        # `send_message/4` already broadcasts to "dm:<id>". This used to
        # broadcast a second time with a payload of its own, so anything on both
        # paths saw the message twice — and the two shapes have since diverged.
        {:noreply, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "failed_to_send"}}, socket}
    end
  end
end
