defmodule ColloqWeb.NotificationLevelTest do
  use ColloqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.{Forum, Subscriptions}

  @endpoint ColloqWeb.Endpoint

  setup do
    author = insert(:user)
    reader = insert(:user)
    topic = insert(:topic, category: insert(:category), user: author)
    insert(:post, topic: topic, user: author, post_number: 1)

    %{author: author, reader: reader, topic: topic}
  end

  defp conn_as(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp choose_level(view, level) do
    view |> element("#header-notif-level-menu") |> render_click(%{"level" => level})
  end

  test "a level chosen in the menu survives a reload", ctx do
    conn = conn_as(ctx.conn, ctx.reader)
    {:ok, view, _html} = live(conn, "/t/#{ctx.topic.id}")

    render_click(view, "set-notification-level", %{"level" => "normal"})
    assert Subscriptions.get_level(ctx.reader.id, ctx.topic.id) == "normal"

    {:ok, _view, _html} = live(conn, "/t/#{ctx.topic.id}")
    assert Subscriptions.get_level(ctx.reader.id, ctx.topic.id) == "normal"
  end

  test "replying does not override a level the reader chose", ctx do
    conn = conn_as(ctx.conn, ctx.reader)
    {:ok, view, _html} = live(conn, "/t/#{ctx.topic.id}")
    render_click(view, "set-notification-level", %{"level" => "normal"})

    {:ok, _post} = Forum.create_post(ctx.topic, ctx.reader, %{"body" => "<p>hola</p>"})

    assert Subscriptions.get_level(ctx.reader.id, ctx.topic.id) == "normal"
  end

  # The reported bug: a topic set to "normal" comes back as "tracking". The only
  # writer of "tracking" is track_if_new/2 on reply, and it must never fire for
  # someone who already has a row — at any level.
  test "replying only sets tracking when the reader has no level of their own", ctx do
    assert Subscriptions.get_level(ctx.reader.id, ctx.topic.id) == "normal"

    {:ok, _post} = Forum.create_post(ctx.topic, ctx.reader, %{"body" => "<p>primera</p>"})
    assert Subscriptions.get_level(ctx.reader.id, ctx.topic.id) == "tracking"

    Subscriptions.set_level(ctx.reader.id, ctx.topic.id, "normal")
    {:ok, _post} = Forum.create_post(ctx.topic, ctx.reader, %{"body" => "<p>segunda</p>"})
    assert Subscriptions.get_level(ctx.reader.id, ctx.topic.id) == "normal"
  end

  test "the menu shows the stored level on mount", ctx do
    Subscriptions.set_level(ctx.reader.id, ctx.topic.id, "normal")

    {:ok, view, _html} = live(conn_as(ctx.conn, ctx.reader), "/t/#{ctx.topic.id}")

    # The menu lists every level, so the stored one has to be read off the
    # trigger button rather than from the presence of a word in the page.
    assert view |> element("#header-notif-level") |> render() =~
             Gettext.gettext(ColloqWeb.Gettext, "Normal")
  end
end
