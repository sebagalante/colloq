defmodule Colloq.Notifications do
  @moduledoc """
  Notifications context.
  In-app + email notifications for mentions, replies, reactions, etc.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Notifications.Notification

  def list_notifications(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    unread_only = Keyword.get(opts, :unread_only, false)

    Notification
    |> where(user_id: ^user_id)
    |> filter_unread(unread_only)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_unread(query, true), do: where(query, read: false)
  defp filter_unread(query, false), do: query

  def create_notification(attrs) do
    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert()
  end

  def mark_read!(notification_id) do
    Notification
    |> where(id: ^notification_id)
    |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])
  end

  def mark_all_read(user_id) do
    Notification
    |> where(user_id: ^user_id, read: false)
    |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])
  end

  def unread_count(user_id) do
    Notification
    |> where(user_id: ^user_id, read: false)
    |> Repo.aggregate(:count, :id)
  end

  def delete_old_notifications(days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    Notification
    |> where([n], n.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end
end
