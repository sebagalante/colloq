defmodule ColloqWeb.ChatNotifierTest do
  @moduledoc """
  The unread count the browser tab reads.

  `#chat-notifier` lives in the app layout and carries the count in
  `data-unread`; the JS hook turns that into the "(2) …" title prefix. If the
  element or the attribute goes missing — or stops updating live — the tab
  silently shows nothing, which is indistinguishable from having no messages.
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

    %{
      conn: Plug.Test.init_test_session(conn, %{"user_id" => me.id}),
      me: me,
      them: them,
      conv: conv
    }
  end

  test "the notifier renders on an ordinary page, not just /messages", ctx do
    {:ok, _view, html} = live(ctx.conn, "/")

    assert html =~ ~s(id="chat-notifier")
    assert html =~ ~s(data-unread="0")
  end

  test "the count reflects unread messages at mount", ctx do
    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "uno")
    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "dos")

    {:ok, _view, html} = live(ctx.conn, "/")

    assert html =~ ~s(data-unread="2")
  end

  test "the count updates live while I'm on another page", ctx do
    {:ok, view, _html} = live(ctx.conn, "/")

    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "recién llegado")

    assert render(view) =~ ~s(data-unread="1")
  end

  test "reading the thread clears it", ctx do
    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "hola")

    {:ok, _view, html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    assert html =~ ~s(data-unread="0")
  end

  test "the count is messages plus notifications", ctx do
    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "un mensaje")

    {:ok, _} =
      Colloq.Notifications.create_notification(%{
        user_id: ctx.me.id,
        type: "mention",
        title: "te mencionaron",
        data: %{"topic_id" => 1}
      })

    {:ok, view, _html} = live(ctx.conn, "/")

    assert render(view) =~ ~s(data-unread="2")
  end

  test "a notification alone shows in the tab count", ctx do
    {:ok, view, _html} = live(ctx.conn, "/")

    {:ok, _} =
      Colloq.Notifications.create_notification(%{
        user_id: ctx.me.id,
        type: "reply",
        title: "te respondieron",
        data: %{"topic_id" => 1, "post_id" => 2}
      })

    assert render(view) =~ ~s(data-unread="1")
  end

  test "a message arriving in an unfocused tab stays unread", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    render_hook(view, "window-focus", %{"focused" => false})
    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "mientras mirás otra cosa")

    assert render(view) =~ ~s(data-unread="1")
  end

  test "coming back to the tab marks the open thread read", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    render_hook(view, "window-focus", %{"focused" => false})
    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "te escribo")
    render_hook(view, "window-focus", %{"focused" => true})

    assert render(view) =~ ~s(data-unread="0")
  end
end
