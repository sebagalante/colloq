defmodule Colloq.Notifications do
  @moduledoc """
  Notifications context.
  In-app + email notifications for mentions, replies, reactions, etc.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Notifications.Notification

  @doc """
  Lists notifications for a user, most recent first.

  ## Options

    * `:limit` - max results (default 50)
    * `:unread_only` - when `true`, returns only unread notifications (default `false`)

  Returns `[%Notification{}]`.
  """
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

  @doc """
  Creates a notification.

  Skips creation if the recipient has blocked the actor (when `actor_id`
  is present in the `data` map).

  Returns `{:ok, notification}`, `{:error, changeset}`, or `{:ok, :skipped}`.
  """
  def create_notification(attrs) do
    data = attrs[:data] || attrs["data"] || %{}
    user_id = attrs[:user_id] || attrs["user_id"]
    actor_id = data["actor_id"] || data[:actor_id]

    if actor_id && user_id && Colloq.Accounts.blocked?(user_id, actor_id) do
      {:ok, :skipped}
    else
      result =
        %Notification{}
        |> Notification.changeset(attrs)
        |> Repo.insert()

      # Live bell badge for the recipient, on whatever page they're on.
      with {:ok, _} <- result, true <- is_integer(user_id) or is_binary(user_id) do
        ColloqWeb.Endpoint.broadcast("user:#{user_id}", "notification", %{})
      end

      result
    end
  end

  @doc """
  Marks a single notification as read.

  Returns `{count, nil}`.
  """
  def mark_read!(notification_id) do
    Notification
    |> where(id: ^notification_id)
    |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])
  end

  @doc """
  Marks all unread notifications for a user as read.

  Returns `{count, nil}`.
  """
  def mark_all_read(user_id) do
    Notification
    |> where(user_id: ^user_id, read: false)
    |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])
  end

  @doc """
  Returns the count of unread notifications for a user.
  """
  def unread_count(user_id) do
    Notification
    |> where(user_id: ^user_id, read: false)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Deletes a single notification (scoped to its owner). Returns `{count, nil}`.
  """
  def delete_notification(notification_id, user_id) do
    Notification
    |> where(id: ^notification_id, user_id: ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes all *read* notifications for a user. Returns `{count, nil}`.
  """
  def delete_read(user_id) do
    Notification
    |> where(user_id: ^user_id, read: true)
    |> Repo.delete_all()
  end

  @doc """
  Deletes every notification for a user. Returns `{count, nil}`.
  """
  def delete_all(user_id) do
    Notification
    |> where(user_id: ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes notifications older than the given number of days (default 90).

  Returns `{count, nil}`.
  """
  def delete_old_notifications(days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    Notification
    |> where([n], n.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end
end
