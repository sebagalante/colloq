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
    archived = Keyword.get(opts, :archived, false)

    Notification
    |> where(user_id: ^user_id)
    |> filter_unread(unread_only)
    |> filter_archived(archived)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_unread(query, true), do: where(query, read: false)
  defp filter_unread(query, false), do: query

  # Archived notifications are hidden from the inbox unless asked for by name,
  # so every existing caller keeps its old meaning.
  defp filter_archived(query, true), do: where(query, [n], not is_nil(n.archived_at))
  defp filter_archived(query, false), do: where(query, [n], is_nil(n.archived_at))

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

  Archived notifications never count: archiving is how a user says they're done
  with something, so an archived-but-unread row must not keep the header badge
  lit with nothing visible in the inbox to clear it.
  """
  def unread_count(user_id) do
    Notification
    |> where(user_id: ^user_id, read: false)
    |> where([n], is_nil(n.archived_at))
    |> Repo.aggregate(:count, :id)
  end

  @doc "How many notifications the user has archived."
  def archived_count(user_id) do
    Notification
    |> where(user_id: ^user_id)
    |> where([n], not is_nil(n.archived_at))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Archives a single notification (scoped to its owner). Returns `{count, nil}`.

  Archiving also marks it read — you can't be "done with" something you never
  saw, and it keeps the badge consistent with what's in the inbox.
  """
  def archive_notification(notification_id, user_id) do
    now = DateTime.utc_now()

    Notification
    |> where(id: ^notification_id, user_id: ^user_id)
    |> where([n], is_nil(n.archived_at))
    |> Repo.update_all(set: [archived_at: now, read: true, read_at: now])
  end

  @doc "Returns an archived notification to the inbox. Returns `{count, nil}`."
  def unarchive_notification(notification_id, user_id) do
    Notification
    |> where(id: ^notification_id, user_id: ^user_id)
    |> Repo.update_all(set: [archived_at: nil])
  end

  @doc """
  Archives every read, non-archived notification for a user. The non-destructive
  counterpart to `delete_read/1`. Returns `{count, nil}`.
  """
  def archive_read(user_id) do
    now = DateTime.utc_now()

    Notification
    |> where(user_id: ^user_id, read: true)
    |> where([n], is_nil(n.archived_at))
    |> Repo.update_all(set: [archived_at: now])
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

  Archived notifications are kept: archiving is an explicit "hold onto this",
  so a retention sweep must not quietly undo it.

  Returns `{count, nil}`.
  """
  def delete_old_notifications(days \\ 90) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    Notification
    |> where([n], n.inserted_at < ^cutoff)
    |> where([n], is_nil(n.archived_at))
    |> Repo.delete_all()
  end
end
