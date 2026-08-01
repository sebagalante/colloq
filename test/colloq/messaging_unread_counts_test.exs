defmodule Colloq.MessagingUnreadCountsTest do
  @moduledoc """
  Per-conversation unread counts behind the sidebar badge.

  `unread_counts/1` has to agree with the header's `unread_count/1` on every
  message it sees, so the cases pinned here are the ones where the two could
  drift: soft-deleted messages, the reader's own messages, and the per-user
  deletion boundary.
  """
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.Messaging
  alias Colloq.Messaging.Message

  setup do
    me = insert(:user)
    them = insert(:user)
    other = insert(:user)
    {:ok, conv} = Messaging.find_or_create_conversation(me.id, them.id)
    {:ok, conv2} = Messaging.find_or_create_conversation(me.id, other.id)
    %{me: me, them: them, other: other, conv: conv, conv2: conv2}
  end

  defp incoming(conv, from, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    Repo.insert!(%Message{
      conversation_id: conv.id,
      user_id: from.id,
      body: "hi",
      read: Keyword.get(opts, :read, false),
      inserted_at: at,
      updated_at: at,
      deleted_at: Keyword.get(opts, :deleted_at)
    })
  end

  test "counts unread messages per conversation", ctx do
    incoming(ctx.conv, ctx.them)
    incoming(ctx.conv, ctx.them)
    incoming(ctx.conv2, ctx.me)

    assert Messaging.unread_counts(ctx.me.id) == %{ctx.conv.id => 2}
  end

  test "omits conversations with nothing unread", ctx do
    incoming(ctx.conv, ctx.them, read: true)

    assert Messaging.unread_counts(ctx.me.id) == %{}
  end

  test "ignores soft-deleted messages", ctx do
    incoming(ctx.conv, ctx.them)
    incoming(ctx.conv, ctx.them, deleted_at: DateTime.utc_now())

    assert Messaging.unread_counts(ctx.me.id) == %{ctx.conv.id => 1}
  end

  test "ignores messages before the reader's deletion boundary", ctx do
    old = DateTime.add(DateTime.utc_now(), -60, :minute)
    incoming(ctx.conv, ctx.them, at: old)
    Messaging.delete_conversation(ctx.conv.id, ctx.me)
    incoming(ctx.conv, ctx.them)

    assert Messaging.unread_counts(ctx.me.id) == %{ctx.conv.id => 1}
  end

  test "sums to the header badge", ctx do
    incoming(ctx.conv, ctx.them)
    incoming(ctx.conv, ctx.them)
    incoming(ctx.conv2, ctx.other)

    counts = Messaging.unread_counts(ctx.me.id)

    assert counts |> Map.values() |> Enum.sum() == Messaging.unread_count(ctx.me.id)
  end

  test "mark_read! clears just that conversation", ctx do
    incoming(ctx.conv, ctx.them)
    incoming(ctx.conv2, ctx.other)

    Messaging.mark_read!(ctx.conv.id, ctx.me.id)

    assert Messaging.unread_counts(ctx.me.id) == %{ctx.conv2.id => 1}
  end
end
