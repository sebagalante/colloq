defmodule ColloqWeb.DmLiveUpdateTest do
  @moduledoc """
  Live delivery of an incoming DM: into the open thread, and into the
  conversation list when the thread *isn't* open.
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
    {:ok, _} = Messaging.send_message(conv.id, them, "arranque")

    %{conn: Plug.Test.init_test_session(conn, %{"user_id" => me.id}), me: me, them: them, conv: conv}
  end

  test "a message sent while I'm viewing the thread appears without a reload", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "llega solo")

    assert render(view) =~ "llega solo"
  end

  test "my own sent message appears in the thread", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages/#{ctx.conv.id}")

    render_submit(element(view, "#chat-form"), %{"body" => "lo mando yo"})

    assert render(view) =~ "lo mando yo"
  end

  test "the conversation list updates while a different thread is open", ctx do
    third = insert(:user)
    {:ok, other_conv} = Messaging.find_or_create_conversation(ctx.me.id, third.id)
    {:ok, _} = Messaging.send_message(other_conv.id, third, "otro hilo")

    # Viewing the *other* conversation when the message lands.
    {:ok, view, _html} = live(ctx.conn, "/messages/#{other_conv.id}")

    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "aviso lateral")

    assert render(view) =~ "aviso lateral"
  end

  test "the conversation list updates with no thread open", ctx do
    {:ok, view, _html} = live(ctx.conn, "/messages")

    {:ok, _} = Messaging.send_message(ctx.conv.id, ctx.them, "sin hilo abierto")

    assert render(view) =~ "sin hilo abierto"
  end
end
