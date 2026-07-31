defmodule Colloq.MessagingPagingTest do
  @moduledoc """
  Keyset pagination for DM threads.

  `list_messages/3` used to return the whole conversation, so a long thread was
  read into the LiveView process in full on every mount. It now returns the
  newest page and walks backwards on a `{inserted_at, id}` cursor — the cases
  worth pinning down are the page boundary, the tie on identical timestamps, and
  the interaction with the two existing visibility rules (soft deletes and the
  per-user deletion boundary).
  """
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.Messaging
  alias Colloq.Messaging.Message

  @page Messaging.page_size()

  setup do
    me = insert(:user)
    them = insert(:user)
    {:ok, conv} = Messaging.find_or_create_conversation(me.id, them.id)
    %{me: me, them: them, conv: conv}
  end

  # Inserted directly so timestamps are explicit — send_message/3 would stamp
  # them all within the same microsecond or two.
  defp message(ctx, body, opts) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    Repo.insert!(%Message{
      conversation_id: ctx.conv.id,
      user_id: ctx.me.id,
      body: body,
      inserted_at: at,
      updated_at: at,
      deleted_at: Keyword.get(opts, :deleted_at)
    })
  end

  defp seed(ctx, count) do
    base = DateTime.add(DateTime.utc_now(), -count, :minute)

    for i <- 1..count do
      message(ctx, "m#{i}", at: DateTime.add(base, i, :minute))
    end
  end

  defp bodies(messages), do: Enum.map(messages, & &1.body)

  describe "first page" do
    test "returns the newest page, oldest first", ctx do
      seed(ctx, @page + 10)

      page = Messaging.list_messages(ctx.conv.id, ctx.me.id)

      assert length(page) == @page
      assert List.first(page).body == "m11"
      assert List.last(page).body == "m#{@page + 10}"
    end

    test "a short thread comes back whole", ctx do
      seed(ctx, 3)

      assert bodies(Messaging.list_messages(ctx.conv.id, ctx.me.id)) == ~w(m1 m2 m3)
    end

    test "an empty thread has nothing to page back from", ctx do
      assert Messaging.list_messages(ctx.conv.id, ctx.me.id) == []
      refute Messaging.more_messages?(ctx.conv.id, ctx.me.id, nil)
    end
  end

  describe "paging backwards" do
    test "walks the whole thread without gaps or repeats", ctx do
      seed(ctx, @page * 2 + 5)

      first = Messaging.list_messages(ctx.conv.id, ctx.me.id)
      second = Messaging.list_messages(ctx.conv.id, ctx.me.id, before: List.first(first))
      third = Messaging.list_messages(ctx.conv.id, ctx.me.id, before: List.first(second))

      all = bodies(third) ++ bodies(second) ++ bodies(first)

      assert all == Enum.map(1..(@page * 2 + 5), &"m#{&1}")
      assert length(Enum.uniq(all)) == length(all)
    end

    test "more_messages? tracks whether history remains", ctx do
      seed(ctx, @page + 1)

      first = Messaging.list_messages(ctx.conv.id, ctx.me.id)
      assert Messaging.more_messages?(ctx.conv.id, ctx.me.id, List.first(first))

      second = Messaging.list_messages(ctx.conv.id, ctx.me.id, before: List.first(first))
      assert bodies(second) == ["m1"]
      refute Messaging.more_messages?(ctx.conv.id, ctx.me.id, List.first(second))
    end

    test "messages sharing a timestamp are split by id, not dropped", ctx do
      at = DateTime.utc_now()
      for i <- 1..4, do: message(ctx, "same#{i}", at: at)

      first = Messaging.list_messages(ctx.conv.id, ctx.me.id, limit: 2)
      second = Messaging.list_messages(ctx.conv.id, ctx.me.id, limit: 2, before: List.first(first))

      assert bodies(first) == ~w(same3 same4)
      assert bodies(second) == ~w(same1 same2)
    end
  end

  describe "visibility rules still apply" do
    test "soft-deleted messages are excluded from every page", ctx do
      base = DateTime.add(DateTime.utc_now(), -10, :minute)
      message(ctx, "keep", at: DateTime.add(base, 1, :minute))
      message(ctx, "gone", at: DateTime.add(base, 2, :minute), deleted_at: DateTime.utc_now())
      message(ctx, "keep2", at: DateTime.add(base, 3, :minute))

      assert bodies(Messaging.list_messages(ctx.conv.id, ctx.me.id)) == ~w(keep keep2)
    end

    test "the deletion boundary hides older history from that user only", ctx do
      base = DateTime.add(DateTime.utc_now(), -10, :minute)
      message(ctx, "before", at: DateTime.add(base, 1, :minute))
      boundary = DateTime.add(base, 2, :minute)
      message(ctx, "after", at: DateTime.add(base, 3, :minute))

      ctx.conv
      |> Ecto.Changeset.change(user1_deleted_at: boundary)
      |> Repo.update!()

      hidden_for = if ctx.conv.user1_id == ctx.me.id, do: ctx.me, else: ctx.them
      other = if hidden_for.id == ctx.me.id, do: ctx.them, else: ctx.me

      assert bodies(Messaging.list_messages(ctx.conv.id, hidden_for.id)) == ["after"]
      assert bodies(Messaging.list_messages(ctx.conv.id, other.id)) == ~w(before after)

      # Nothing older is reachable by paging past the boundary either.
      page = Messaging.list_messages(ctx.conv.id, hidden_for.id)
      refute Messaging.more_messages?(ctx.conv.id, hidden_for.id, List.first(page))
    end
  end
end
