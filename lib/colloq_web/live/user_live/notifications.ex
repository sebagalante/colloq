defmodule ColloqWeb.UserLive.Notifications do
  @moduledoc """
  Notifications inbox: lists a user's notifications, marks them read, and links
  each one to the content it refers to (topic/post/profile).
  """
  use ColloqWeb, :live_view

  alias Colloq.Notifications

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case session["user_id"] do
        nil -> nil
        user_id -> Colloq.Accounts.get_user!(user_id)
      end

    if current_user do
      {:ok,
       socket
       |> assign(:current_user, current_user)
       |> assign(:page_title, gettext("Notifications"))
       |> load_notifications()}
    else
      {:ok, push_navigate(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("mark-all-read", _params, socket) do
    Notifications.mark_all_read(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> load_notifications()
     |> assign(:unread_notifications, 0)}
  end

  # Remove a single notification from the DB.
  def handle_event("delete", %{"id" => id}, socket) do
    Notifications.delete_notification(String.to_integer(id), socket.assigns.current_user.id)
    {:noreply, load_notifications(socket)}
  end

  # Remove all already-read notifications from the DB.
  def handle_event("clear-read", _params, socket) do
    {count, _} = Notifications.delete_read(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> load_notifications()
     |> put_flash(:info, gettext("Removed %{count} read notifications.", count: count))}
  end

  # Remove every notification from the DB.
  def handle_event("clear-all", _params, socket) do
    Notifications.delete_all(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> load_notifications()
     |> put_flash(:info, gettext("All notifications removed."))}
  end

  def handle_event("open", %{"id" => id}, socket) do
    notification = Enum.find(socket.assigns.notifications, &(to_string(&1.id) == id))

    if notification do
      unless notification.read, do: Notifications.mark_read!(notification.id)
      {:noreply, push_navigate(socket, to: notification_path(notification))}
    else
      {:noreply, socket}
    end
  end

  defp load_notifications(socket) do
    user = socket.assigns.current_user
    notifications = Notifications.list_notifications(user.id, limit: 50)

    socket
    |> assign(:notifications, notifications)
    |> assign(:unread_notifications, Notifications.unread_count(user.id))
  end

  # Build a link target from the notification's data map.
  def notification_path(%{data: data}) when is_map(data) do
    topic_id = data["topic_id"] || data[:topic_id]
    post_id = data["post_id"] || data[:post_id]
    username = data["actor_username"] || data[:actor_username]

    cond do
      topic_id && post_id -> "/t/#{topic_id}#post-#{post_id}"
      topic_id -> "/t/#{topic_id}"
      username -> "/u/#{username}"
      true -> "/notifications"
    end
  end

  def notification_path(_), do: "/notifications"

  def notification_icon(type) do
    case type do
      "mention" -> "at-sign"
      "reply" -> "reply"
      "reaction" -> "thumbs-up"
      "message" -> "mail"
      _ -> "bell"
    end
  end
end
