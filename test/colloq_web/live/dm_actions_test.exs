defmodule ColloqWeb.DmActionsTest do
  @moduledoc """
  Hover actions on DM bubbles: which of react/reply/delete appear on your own
  messages versus the other participant's, and that replying to theirs works.
  """
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.Messaging

  @endpoint ColloqWeb.Endpoint

  setup %{conn: conn} do
    me = insert(:user)
    them = insert(:user)
    {:ok, conv} = Messaging.find_or_create_conversation(me.id, them.id)
    {:ok, theirs} = Messaging.send_message(conv.id, them, "mensaje de ellos")
    {:ok, mine} = Messaging.send_message(conv.id, me, "mensaje mío")

    conn = Plug.Test.init_test_session(conn, %{"user_id" => me.id})

    %{conn: conn, me: me, them: them, conv: conv, theirs: theirs, mine: mine}
  end

  test "the reply button is offered on both sides", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    assert has_element?(view, ~s|button[phx-click="reply-to"][phx-value-id="#{ctx.theirs.id}"]|)
    assert has_element?(view, ~s|button[phx-click="reply-to"][phx-value-id="#{ctx.mine.id}"]|)
  end

  test "delete is offered only on my own messages", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    assert has_element?(view, ~s|button[phx-value-id="#{ctx.mine.id}"][phx-click="delete-message"]|)
    refute has_element?(
             view,
             ~s|button[phx-value-id="#{ctx.theirs.id}"][phx-click="delete-message"]|
           )
  end

  test "replying to their message quotes them in the composer", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    html =
      view
      |> element(~s|button[phx-click="reply-to"][phx-value-id="#{ctx.theirs.id}"]|)
      |> render_click()

    assert html =~ "mensaje de ellos"
    assert html =~ ctx.them.display_name || html =~ ctx.them.username
  end

  test "the quoted reply is sent and rendered", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    view
    |> element(~s|button[phx-click="reply-to"][phx-value-id="#{ctx.theirs.id}"]|)
    |> render_click()

    render_submit(element(view, "#chat-form"), %{"body" => "respondiendo"})

    reply = Messaging.list_messages(ctx.conv.id, ctx.me.id) |> List.last()
    assert reply.body == "respondiendo"
    assert reply.reply_to_id == ctx.theirs.id
  end
end
