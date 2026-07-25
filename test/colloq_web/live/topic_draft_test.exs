defmodule ColloqWeb.TopicDraftTest do
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.Forum

  @endpoint ColloqWeb.Endpoint

  setup do
    author = insert(:user)
    user = insert(:user)
    topic = insert(:topic, category: insert(:category), user: author)
    insert(:post, topic: topic, user: author, post_number: 1)

    %{author: author, user: user, topic: topic}
  end

  defp open(conn, topic, user) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    live(conn, "/t/#{topic.id}")
  end

  # The button submits the reply form with its own param, so the draft branch
  # has to win over the post branch — otherwise "save draft" publishes.
  defp save_draft(view, body) do
    view
    |> element("form[phx-submit='reply']")
    |> render_submit(%{"body" => body, "draft" => "1"})
  end

  describe "saving" do
    test "the composer offers a save-draft button", %{conn: conn, topic: topic, user: user} do
      {:ok, _view, html} = open(conn, topic, user)

      assert html =~ "Save draft" or html =~ "Guardar borrador"
    end

    test "saving stores the body without posting it", %{conn: conn, topic: topic, user: user} do
      {:ok, view, _html} = open(conn, topic, user)

      before_count = Forum.count_root_posts(topic.id)
      save_draft(view, "<p>casi listo</p>")

      assert %{body: "<p>casi listo</p>"} = Forum.get_draft(user.id, topic.id)
      assert Forum.count_root_posts(topic.id) == before_count
    end

    test "saving twice overwrites rather than accumulating", %{
      conn: conn,
      topic: topic,
      user: user
    } do
      {:ok, view, _html} = open(conn, topic, user)

      save_draft(view, "<p>uno</p>")
      first = Forum.get_draft(user.id, topic.id)
      save_draft(view, "<p>dos</p>")
      second = Forum.get_draft(user.id, topic.id)

      assert first.id == second.id
      assert second.body == "<p>dos</p>"
    end

    test "an empty composer clears the draft instead of storing blank", %{
      conn: conn,
      topic: topic,
      user: user
    } do
      {:ok, view, _html} = open(conn, topic, user)

      save_draft(view, "<p>algo</p>")
      assert Forum.get_draft(user.id, topic.id)

      save_draft(view, "<p></p>")
      refute Forum.get_draft(user.id, topic.id)
    end

    test "drafts are per user", %{conn: conn, topic: topic, user: user, author: author} do
      {:ok, view, _html} = open(conn, topic, user)
      save_draft(view, "<p>mío</p>")

      assert Forum.get_draft(user.id, topic.id)
      refute Forum.get_draft(author.id, topic.id)
    end
  end

  describe "restoring" do
    test "a saved draft comes back in the composer on the next visit", %{
      conn: conn,
      topic: topic,
      user: user
    } do
      {:ok, _draft} = Forum.save_draft(user.id, topic.id, %{body: "<p>volvé a mí</p>"})

      {:ok, _view, html} = open(conn, topic, user)

      # The Tiptap hook boots from this input's value, so the body being here
      # is what "restored" means on the client.
      assert html =~ ~s(id="reply-body-input")
      assert html =~ "volvé a mí"
      assert html =~ "restored" or html =~ "restauramos" or html =~ "borrador"
    end

    # Arriving from "My drafts". Without this the thread loads at the top and
    # the composer holding the draft is somewhere below the fold.
    test "?draft=1 focuses the composer", %{conn: conn, topic: topic, user: user} do
      {:ok, _draft} = Forum.save_draft(user.id, topic.id, %{body: "<p>seguimos</p>"})

      conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
      {:ok, view, html} = live(conn, "/t/#{topic.id}?draft=1")

      assert html =~ "seguimos"
      assert_push_event(view, "tiptap:focus", %{target: "reply-editor"})
    end

    test "no draft means no restore notice", %{conn: conn, topic: topic, user: user} do
      {:ok, _view, html} = open(conn, topic, user)

      refute html =~ "We restored your saved draft."
    end

    test "discarding removes the saved copy", %{conn: conn, topic: topic, user: user} do
      {:ok, _draft} = Forum.save_draft(user.id, topic.id, %{body: "<p>chau</p>"})
      {:ok, view, _html} = open(conn, topic, user)

      view |> element("button[phx-click='discard-draft']") |> render_click()

      refute Forum.get_draft(user.id, topic.id)
    end

    # Discard drops the stored draft; it must not wipe the composer the user is
    # looking at. Clearing the editor there destroyed unsaved work behind a
    # button that only promised to dismiss a notice.
    test "discarding leaves the editor content alone", %{conn: conn, topic: topic, user: user} do
      {:ok, _draft} = Forum.save_draft(user.id, topic.id, %{body: "<p>chau</p>"})
      {:ok, view, _html} = open(conn, topic, user)

      html = view |> element("button[phx-click='discard-draft']") |> render_click()

      refute html =~ "phx-event=\"tiptap:clear\""
      refute render(view) =~ "We restored your saved draft."
    end
  end

  describe "posting" do
    test "posting the reply consumes the draft", %{conn: conn, topic: topic, user: user} do
      {:ok, view, _html} = open(conn, topic, user)

      save_draft(view, "<p>pendiente</p>")
      assert Forum.get_draft(user.id, topic.id)

      view
      |> element("form[phx-submit='reply']")
      |> render_submit(%{"body" => "<p>pendiente</p>"})

      refute Forum.get_draft(user.id, topic.id)
    end
  end
end
