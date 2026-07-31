defmodule Colloq.Messaging do
  @moduledoc """
  Direct messaging context.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Messaging.{Conversation, Message}

  # Everything a bubble needs to render: who wrote it and what it quotes.
  # `:user` is loaded on the message itself as well as on the quoted parent —
  # quoting one of *their* messages reads the author off the message you picked,
  # not off its parent, and an unloaded association crashed the LiveView there.
  @display_preloads [:user, reply_to: :user]

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
           (is_nil(c.user1_deleted_at) or
              (not is_nil(lm.id) and lm.inserted_at > c.user1_deleted_at))) or
          (c.user2_id == ^user_id and
             (is_nil(c.user2_deleted_at) or
                (not is_nil(lm.id) and lm.inserted_at > c.user2_deleted_at))),
      order_by: [desc: c.updated_at],
      preload: [:user1, :user2, :last_message]
    )
    |> Repo.all()
  end

  def get_conversation!(id),
    do: Repo.get!(Conversation, id) |> Repo.preload([:messages, :user1, :user2])

  @doc "The user's deletion boundary for a conversation (nil if never deleted)."
  def deletion_boundary(%Conversation{user1_id: id1} = c, user_id) do
    if user_id == id1, do: c.user1_deleted_at, else: c.user2_deleted_at
  end

  @page_size 50

  @doc "Messages loaded per page."
  def page_size, do: @page_size

  @doc """
  One page of a conversation's messages visible to `user_id`, oldest first.

  Returns the *newest* #{@page_size} by default. Pass `before: message` — the
  oldest message already on screen — to walk backwards through history; the
  cursor is `{inserted_at, id}` rather than an offset, so pages stay stable
  while new messages arrive at the other end.

  This used to load every message in the conversation on every mount, which
  meant a long-running thread was read in full into the LiveView process (and
  pushed to the client) each time it was opened.

  Excludes soft-deleted messages and anything before the user's deletion
  boundary (so a reopened conversation starts fresh).
  """
  def list_messages(conversation_id, user_id, opts \\ []) do
    page_size = Keyword.get(opts, :limit, @page_size)

    conversation_id
    |> visible_messages_query(user_id)
    |> older_than(Keyword.get(opts, :before))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^page_size)
    |> Repo.all()
    |> Repo.preload(@display_preloads)
    # The query walks backwards from the newest; the thread renders forwards.
    |> Enum.reverse()
  end

  @doc """
  A single message ready to render, or nil.

  The live-append path fetches the real row rather than reconstructing one from
  the broadcast payload — a hand-built map can't carry the quoted parent or a
  usable database id.
  """
  def get_message_for_display(message_id) do
    case Repo.get(Message, message_id) do
      nil -> nil
      message -> Repo.preload(message, @display_preloads)
    end
  end

  @doc """
  Whether any visible message sits before `cursor` — i.e. whether the thread
  has more history to load. `nil` means nothing is on screen yet, so there is
  nothing to page back from.
  """
  def more_messages?(conversation_id, user_id, cursor)

  def more_messages?(_conversation_id, _user_id, nil), do: false

  def more_messages?(conversation_id, user_id, cursor) do
    conversation_id
    |> visible_messages_query(user_id)
    |> older_than(cursor)
    |> Repo.exists?()
  end

  defp visible_messages_query(conversation_id, user_id) do
    boundary =
      case Repo.get(Conversation, conversation_id) do
        nil -> nil
        conv -> deletion_boundary(conv, user_id)
      end

    q = from(m in Message, where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at))

    if boundary, do: where(q, [m], m.inserted_at > ^boundary), else: q
  end

  # Keyset predicate. `inserted_at` alone isn't a key — two messages can share a
  # timestamp — so `id` breaks the tie and keeps the page boundary exact.
  defp older_than(q, nil), do: q

  defp older_than(q, %{inserted_at: ts, id: id}) do
    where(q, [m], m.inserted_at < ^ts or (m.inserted_at == ^ts and m.id < ^id))
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
    - and neither user may have *blocked* the other. (A one-way "ignore" only
      hides forum posts and does not sever the DM channel.)

  Returns `:ok`, `{:error, :blocked}`, or `{:error, :opted_out}`.
  """
  def can_message?(%Colloq.Accounts.User{} = actor, %Colloq.Accounts.User{} = target) do
    cond do
      # Bots have no inbox — nothing reads a DM sent to a system account, so
      # the conversation would be a dead end. Checked before the staff bypass:
      # this is a capability the target lacks, not a permission the actor has.
      # Reuses :opted_out rather than a new atom so every existing call site
      # keeps working; "isn't accepting messages" is true of a bot.
      target.flair == "BOT" ->
        {:error, :opted_out}

      actor.role in @staff_roles ->
        :ok

      Colloq.Accounts.dm_blocked?(actor.id, target.id) ->
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

  @doc """
  Sends a text message, optionally quoting an earlier one via `reply_to_id`.

  A quoted message that isn't in this conversation is dropped rather than
  rejected — the id comes from the client, and a stray one shouldn't be able to
  pull a bubble from someone else's thread into this one.
  """
  def send_message(conversation_id, %Colloq.Accounts.User{} = user, body, reply_to_id \\ nil) do
    create_message(conversation_id, user, %{
      "body" => body,
      "reply_to_id" => sanitize_reply_to(conversation_id, reply_to_id)
    })
  end

  defp sanitize_reply_to(_conversation_id, nil), do: nil

  defp sanitize_reply_to(conversation_id, reply_to_id) do
    Message
    |> where([m], m.id == ^reply_to_id and m.conversation_id == ^conversation_id)
    |> select([m], m.id)
    |> Repo.one()
  end

  @doc """
  Sends a sticker.

  `url` must already have been checked against the sticker catalogue by the
  caller — this writes it straight to the message.
  """
  def send_sticker(conversation_id, %Colloq.Accounts.User{} = user, url) do
    create_message(conversation_id, user, %{"sticker_url" => url})
  end

  defp create_message(conversation_id, %Colloq.Accounts.User{} = user, attrs) do
    result =
      %Message{}
      |> Message.changeset(
        Map.merge(attrs, %{"conversation_id" => conversation_id, "user_id" => user.id})
      )
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
        # Only the id travels: each viewer loads the row itself, so the bubble
        # they render is the real record with its quoted parent attached.
        ColloqWeb.Endpoint.broadcast("dm:#{conversation_id}", "new_message", %{
          sender_id: user.id,
          message_id: message.id
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

        # Separate topic from "user:<id>". That one is owned by the global
        # `live_badges_hook` in UserAuth, which halts "message_received" so it
        # never reaches a LiveView's own handle_info — the header badge updated
        # while the conversation list sat stale. Both participants are told, so
        # a second tab open on the list reorders too.
        for id <- [u1, u2] do
          ColloqWeb.Endpoint.broadcast("dm_list:#{id}", "conversations_changed", %{})
        end

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
    {count, _} =
      Message
      |> where(conversation_id: ^conversation_id)
      |> where([m], m.user_id != ^user_id)
      |> where(read: false)
      |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])

    # Tell the sender (also viewing this conversation) that their messages were
    # read, so their delivery checks turn into blue double checks live.
    if count > 0 do
      ColloqWeb.Endpoint.broadcast("dm:#{conversation_id}", "read", %{reader_id: user_id})
    end

    count
  end
end
