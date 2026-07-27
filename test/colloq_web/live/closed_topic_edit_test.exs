defmodule ColloqWeb.ClosedTopicEditTest do
  use ColloqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.Forum
  alias Colloq.Repo

  @endpoint ColloqWeb.Endpoint

  setup do
    author = insert(:user)
    topic = insert(:topic, category: insert(:category), user: author)
    insert(:post, topic: topic, user: author, post_number: 1)
    %{author: author, topic: topic}
  end

  # category_id is required by the changeset, so it has to be sent for the
  # allowed cases to actually succeed — without it every edit fails validation
  # and the negative tests would pass for the wrong reason.
  defp edit(view, topic, title) do
    render_hook(view, "save-edit-topic", %{
      "title" => title,
      "tags" => "",
      "category_id" => to_string(topic.category_id)
    })
  end

  defp open_as(conn, user, topic) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    live(conn, "/t/#{topic.id}")
  end

  defp close(topic), do: topic |> Ecto.Changeset.change(closed: true) |> Repo.update!()
  defp archive(topic), do: topic |> Ecto.Changeset.change(archived: true) |> Repo.update!()

  test "author may edit their own open topic", ctx do
    {:ok, view, _html} = open_as(ctx.conn, ctx.author, ctx.topic)

    edit(view, ctx.topic, "A new title")

    assert Forum.get_topic!(ctx.topic.id).title == "A new title"
  end

  test "author cannot edit a topic staff closed", ctx do
    closed = close(ctx.topic)
    {:ok, view, _html} = open_as(ctx.conn, ctx.author, closed)

    # Pushed directly rather than via the button: hiding the control is not a
    # permission check, and the author is exactly who would try this.
    edit(view, closed, "Sneaky retitle")

    assert Forum.get_topic!(closed.id).title == ctx.topic.title
  end

  test "author cannot edit an archived topic", ctx do
    archived = archive(ctx.topic)
    {:ok, view, _html} = open_as(ctx.conn, ctx.author, archived)

    edit(view, archived, "Sneaky retitle")

    assert Forum.get_topic!(archived.id).title == ctx.topic.title
  end

  test "the edit control disappears for the author once the topic is closed", ctx do
    {:ok, _view, open_html} = open_as(ctx.conn, ctx.author, ctx.topic)
    assert open_html =~ "start-edit-topic"

    {:ok, _view, closed_html} = open_as(ctx.conn, ctx.author, close(ctx.topic))
    refute closed_html =~ "start-edit-topic"
  end

  test "moderators can still edit a closed topic, so the lock stays recoverable", ctx do
    mod = insert(:user, role: "moderator")
    closed = close(ctx.topic)

    {:ok, view, html} = open_as(ctx.conn, mod, closed)
    assert html =~ "start-edit-topic"

    edit(view, closed, "Moderated title")

    assert Forum.get_topic!(closed.id).title == "Moderated title"
  end

  test "author still cannot reply to a closed topic", ctx do
    closed = close(ctx.topic)

    refute Forum.can_reply?(closed, ctx.author)
    assert {:error, :topic_closed} = Forum.create_post(closed, ctx.author, %{"body" => "hi"})
  end
end
