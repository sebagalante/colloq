defmodule ColloqWeb.TopicSortTest do
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory

  @endpoint ColloqWeb.Endpoint

  # Assertions run against the rendered DOM order — what the user actually
  # sees — rather than the return of sorted_posts/2, so a sort that works in
  # isolation but never reaches the page still fails.
  defp post_id_order(html) do
    Regex.scan(~r/id="post-(\d+)"/, html)
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
    |> Enum.uniq()
  end

  defp open_topic(conn, topic, user) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, view, html} = live(conn, "/t/#{topic.id}")
    {view, post_id_order(html)}
  end

  defp click_top(view) do
    view |> element("button[phx-click='toggle-sort']") |> render_click() |> post_id_order()
  end

  setup do
    author = insert(:user)
    topic = insert(:topic, category: insert(:category), user: author)
    op = insert(:post, topic: topic, user: author, post_number: 1, reactions_count: 0)
    %{author: author, topic: topic, op: op}
  end

  test "ranks replies by reactions, OP pinned first", ctx do
    %{conn: conn, author: author, topic: topic, op: op} = ctx

    _low = insert(:post, topic: topic, user: author, post_number: 2, reactions_count: 0)
    high = insert(:post, topic: topic, user: author, post_number: 3, reactions_count: 9)

    {view, chrono} = open_topic(conn, topic, author)
    top = click_top(view)

    refute chrono == top, "clicking Top replies did not change the rendered order"
    assert hd(top) == op.id, "the opening post should stay pinned first"

    assert Enum.at(top, 1) == high.id,
           "expected the 9-reaction post first among replies, got #{inspect(top)}"
  end

  test "breaks equal-reaction ties by subthread reactions", ctx do
    %{conn: conn, author: author, topic: topic} = ctx

    # Both have one reaction — the pre-existing sort left these in posting
    # order, which is the case that made the button look inert.
    dead_end = insert(:post, topic: topic, user: author, post_number: 2, reactions_count: 1)
    discussed = insert(:post, topic: topic, user: author, post_number: 3, reactions_count: 1)

    insert(:post,
      topic: topic,
      user: author,
      post_number: 4,
      parent_id: discussed.id,
      reactions_count: 5
    )

    {view, _chrono} = open_topic(conn, topic, author)
    top = click_top(view)

    assert Enum.find_index(top, &(&1 == discussed.id)) <
             Enum.find_index(top, &(&1 == dead_end.id)),
           "a reply whose subthread drew reactions should outrank an equally-liked dead end"
  end

  test "breaks remaining ties by reply count", ctx do
    %{conn: conn, author: author, topic: topic} = ctx

    quiet = insert(:post, topic: topic, user: author, post_number: 2, reactions_count: 0)
    busy = insert(:post, topic: topic, user: author, post_number: 3, reactions_count: 0)

    for n <- 4..6 do
      insert(:post,
        topic: topic,
        user: author,
        post_number: n,
        parent_id: busy.id,
        reactions_count: 0
      )
    end

    {view, _chrono} = open_topic(conn, topic, author)
    top = click_top(view)

    assert Enum.find_index(top, &(&1 == busy.id)) < Enum.find_index(top, &(&1 == quiet.id)),
           "with no reactions anywhere, the post that drew replies should rank higher"
  end

  test "chrono mode is unchanged and toggling back restores posting order", ctx do
    %{conn: conn, author: author, topic: topic} = ctx

    insert(:post, topic: topic, user: author, post_number: 2, reactions_count: 0)
    insert(:post, topic: topic, user: author, post_number: 3, reactions_count: 9)

    {view, chrono} = open_topic(conn, topic, author)

    _top = click_top(view)
    back = click_top(view)

    assert back == chrono, "toggling off should restore the original posting order"
  end
end
