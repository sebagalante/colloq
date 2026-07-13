defmodule Colloq.Messaging do
  @moduledoc """
  Direct messaging context.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Messaging.{Conversation, Message}

  # Deletion model (WhatsApp/Telegram style): deleting a conversation records a
  # per-user timestamp (`userN_deleted_at`). That timestamp is a boundary — the
  # user no longer sees the conversation or any message from before it. Messages
  # sent *after* it reappear (a fresh thread), so reopening someone you deleted
  # starts empty rather than resurrecting old history.
  def list_conversations(user_id) do
    from(c in Conversation,
      left_join: lm in Message,
      on: lm.id == c.last_message_id,
      where: c.user1_id == ^user_id or c.user2_id == ^user_id,
      # Visible if the user never deleted it, or there's a message after their
      # deletion boundary.
      where:
        (c.user1_id == ^user_id and
           (is_nil(c.user1_deleted_at) or (not is_nil(lm.id) and lm.inserted_at > c.user1_deleted_at))) or
          (c.user2_id == ^user_id and
             (is_nil(c.user2_deleted_at) or (not is_nil(lm.id) and lm.inserted_at > c.user2_deleted_at))),
      order_by: [desc: c.updated_at],
      preload: [:user1, :user2, :last_message]
    )
    |> Repo.all()
  end

  def get_conversation!(id), do: Repo.get!(Conversation, id) |> Repo.preload([:messages, :user1, :user2])

  @doc "The user's deletion boundary for a conversation (nil if never deleted)."
  def deletion_boundary(%Conversation{user1_id: id1} = c, user_id) do
    if user_id == id1, do: c.user1_deleted_at, else: c.user2_deleted_at
  end

  @doc """
  Messages of a conversation visible to `user_id`, oldest first.

  Excludes soft-deleted messages and anything before the user's deletion
  boundary (so a reopened conversation starts fresh).
  """
  def list_messages(conversation_id, user_id) do
    boundary =
      case Repo.get(Conversation, conversation_id) do
        nil -> nil
        conv -> deletion_boundary(conv, user_id)
      end

    q =
      from(m in Message,
        where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
        order_by: [asc: m.inserted_at]
      )

    q = if boundary, do: where(q, [m], m.inserted_at > ^boundary), else: q

    Repo.all(q)
  end

  @doc """
  Soft-deletes a single message. Only the message's author may delete it.
  Returns `{:ok, message}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.
  """
  def delete_message(message_id, %Colloq.Accounts.User{} = user) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      %Message{user_id: uid} = message when uid == user.id ->
        message
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update()

      _ ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Hides a conversation for one participant ("delete for me"). The other
  participant keeps their copy; a future message makes it reappear.
  """
  def delete_conversation(conversation_id, %Colloq.Accounts.User{} = user) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      %Conversation{user1_id: id1, user2_id: id2} = conv when user.id in [id1, id2] ->
        field = if user.id == id1, do: :user1_deleted_at, else: :user2_deleted_at

        conv
        |> Ecto.Changeset.change(%{field => DateTime.utc_now()})
        |> Repo.update()

      _ ->
        {:error, :unauthorized}
    end
  end

  @doc "Like get_conversation!/1 but returns nil instead of raising when missing."
  def get_conversation(id) do
    case Repo.get(Conversation, id) do
      nil -> nil
      conv -> Repo.preload(conv, [:messages, :user1, :user2])
    end
  end

  @staff_roles ~w(moderator admin super_admin)

  @doc """
  Whether `actor` is allowed to send a direct message to `target`.

  Rules:
    - staff (moderator/admin/super_admin) can always message anyone;
    - otherwise the target must have `allow_messages` enabled;
    - and neither user may have blocked the other.

  Returns `:ok`, `{:error, :blocked}`, or `{:error, :opted_out}`.
  """
  def can_message?(%Colloq.Accounts.User{} = actor, %Colloq.Accounts.User{} = target) do
    cond do
      actor.role in @staff_roles ->
        :ok

      Colloq.Accounts.blocked?(target.id, actor.id) or Colloq.Accounts.blocked?(actor.id, target.id) ->
        {:error, :blocked}

      target.allow_messages == false ->
        {:error, :opted_out}

      true ->
        :ok
    end
  end

  def find_or_create_conversation(user1_id, user2_id) do
    [min_id, max_id] = Enum.sort([user1_id, user2_id])

    case Repo.get_by(Conversation, user1_id: min_id, user2_id: max_id) do
      nil ->
        %Conversation{}
        |> Conversation.changeset(%{user1_id: min_id, user2_id: max_id})
        |> Repo.insert()

      conv ->
        {:ok, conv}
    end
  end

  def send_message(conversation_id, %Colloq.Accounts.User{} = user, body) do
    create_message(conversation_id, user, %{"body" => body})
  end

  @doc """
  Sends a message with a file attachment (and optional text body).

  `attachment` is a map with `:url`, `:name` and `:type` keys.
  """
  def send_attachment(conversation_id, %Colloq.Accounts.User{} = user, attachment, body \\ "") do
    create_message(conversation_id, user, %{
      "body" => body,
      "attachment_url" => attachment[:url] || attachment["url"],
      "attachment_name" => attachment[:name] || attachment["name"],
      "attachment_type" => attachment[:type] || attachment["type"]
    })
  end

  defp create_message(conversation_id, %Colloq.Accounts.User{} = user, attrs) do
    result =
      %Message{}
      |> Message.changeset(Map.merge(attrs, %{"conversation_id" => conversation_id, "user_id" => user.id}))
      |> Repo.insert()

    case result do
      {:ok, message} ->
        # Point the conversation at this message and bump it to the top of the
        # list. Deletion marks are NOT cleared — the boundary logic in
        # list_conversations/list_messages makes the thread reappear (fresh,
        # without old history) once there's a message after the mark.
        from(c in Conversation, where: c.id == ^conversation_id)
        |> Repo.update_all(set: [last_message_id: message.id, updated_at: DateTime.utc_now()])

        # Notify everyone viewing this conversation (sender included, so their
        # own message appears without a manual refresh).
        ColloqWeb.Endpoint.broadcast("dm:#{conversation_id}", "new_message", %{
          sender_id: user.id,
          body: message.body,
          attachment_url: message.attachment_url,
          attachment_name: message.attachment_name,
          attachment_type: message.attachment_type,
          timestamp: message.inserted_at
        })

        # Notify the recipient's per-user channel so their header badge updates
        # live even if they're on another page.
        notify_recipient(conversation_id, user.id)

        {:ok, message}

      error ->
        error
    end
  end

  defp notify_recipient(conversation_id, sender_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{user1_id: u1, user2_id: u2} ->
        recipient_id = if u1 == sender_id, do: u2, else: u1
        ColloqWeb.Endpoint.broadcast("user:#{recipient_id}", "message_received", %{})

      _ ->
        :ok
    end
  end

  @doc """
  Count of unread messages addressed to `user_id`.

  Excludes soft-deleted messages and conversations the user has deleted for
  themselves — otherwise the mail badge could count messages the user can no
  longer see or mark read.
  """
  def unread_count(user_id) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: m.user_id != ^user_id and m.read == false and is_nil(m.deleted_at),
      # Only messages after the user's deletion boundary count.
      where:
        (c.user1_id == ^user_id and
           (is_nil(c.user1_deleted_at) or m.inserted_at > c.user1_deleted_at)) or
          (c.user2_id == ^user_id and
             (is_nil(c.user2_deleted_at) or m.inserted_at > c.user2_deleted_at))
    )
    |> Repo.aggregate(:count, :id)
  end

  def mark_read!(conversation_id, user_id) do
    Message
    |> where(conversation_id: ^conversation_id)
    |> where([m], m.user_id != ^user_id)
    |> where(read: false)
    |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])
  end
end
