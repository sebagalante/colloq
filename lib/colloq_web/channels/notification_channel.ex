defmodule ColloqWeb.NotificationChannel do
  use Phoenix.Channel

  def join("notifications:" <> user_id, _payload, socket) do
    if to_string(socket.assigns.user_id) == user_id do
      {:ok, assign(socket, :user_id, user_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  intercept ["new_notification", "unread_count_update"]
end
