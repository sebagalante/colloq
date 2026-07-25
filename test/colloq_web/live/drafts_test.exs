defmodule ColloqWeb.DraftsTest do
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.Forum

  @endpoint ColloqWeb.Endpoint

  setup do
    user = insert(:user)
    other = insert(:user)
    category = insert(:category, name: "General")
    topic = insert(:topic, category: category, user: user, title: "Un tema cualquiera")

    %{user: user, other: other, topic: topic, category: category}
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    live(conn, "/drafts")
  end

  test "requires a session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/drafts")
  end

  test "empty state when nothing is saved", %{conn: conn, user: user} do
    {:ok, _view, html} = open(conn, user)

    assert html =~ "No drafts yet." or html =~ "Todavía no"
  end

  test "lists drafts with topic, category and body preview", %{
    conn: conn,
    user: user,
    topic: topic
  } do
    {:ok, _} = Forum.save_draft(user.id, topic.id, %{body: "<p>esto es un borrador</p>"})

    {:ok, _view, html} = open(conn, user)

    assert html =~ "Un tema cualquiera"
    assert html =~ "esto es un borrador"
    assert html =~ "General"
    # Rows land on the composer itself (?draft=1 scrolls and focuses it), not
    # the top of the thread with the draft below the fold.
    assert html =~ ~s(href="/t/#{topic.id}?draft=1#reply-composer")
  end

  test "a new-topic draft is labelled and points at the composer", %{conn: conn, user: user} do
    {:ok, _} = Forum.save_draft(user.id, nil, %{body: "<p>tema nuevo sin publicar</p>"})

    {:ok, _view, html} = open(conn, user)

    assert html =~ "tema nuevo sin publicar"
    assert html =~ ~s(href="/forum/new")
  end

  test "only shows your own drafts", %{conn: conn, user: user, other: other, topic: topic} do
    {:ok, _} = Forum.save_draft(user.id, topic.id, %{body: "<p>mío</p>"})
    {:ok, _} = Forum.save_draft(other.id, topic.id, %{body: "<p>ajeno</p>"})

    {:ok, _view, html} = open(conn, user)

    assert html =~ "mío"
    refute html =~ "ajeno"
  end

  test "newest edit first", %{conn: conn, user: user, topic: topic, category: category} do
    older = insert(:topic, category: category, user: user, title: "Tema viejo")
    {:ok, _} = Forum.save_draft(user.id, older.id, %{body: "<p>viejo</p>"})
    {:ok, _} = Forum.save_draft(user.id, topic.id, %{body: "<p>reciente</p>"})

    {:ok, _view, html} = open(conn, user)

    assert :binary.match(html, "reciente") < :binary.match(html, "viejo")
  end

  test "deleting removes the row", %{conn: conn, user: user, topic: topic} do
    {:ok, draft} = Forum.save_draft(user.id, topic.id, %{body: "<p>chau</p>"})

    {:ok, view, _html} = open(conn, user)
    html = view |> element("button[phx-value-draft_id='#{draft.id}']") |> render_click()

    refute html =~ "chau"
    refute Forum.get_draft(user.id, topic.id)
  end

  # Ids are sequential, so the delete path has to be scoped to the owner.
  test "cannot delete someone else's draft by id", %{
    conn: conn,
    user: user,
    other: other,
    topic: topic
  } do
    {:ok, theirs} = Forum.save_draft(other.id, topic.id, %{body: "<p>ajeno</p>"})

    {:ok, view, _html} = open(conn, user)
    render_hook_result = render_click(view, "delete-draft", %{"draft_id" => to_string(theirs.id)})

    assert render_hook_result =~ "No drafts yet." or render_hook_result =~ "Todavía no"
    assert Forum.get_draft(other.id, topic.id)
  end

  test "count_drafts/1 counts only that user's", %{user: user, other: other, topic: topic} do
    {:ok, _} = Forum.save_draft(user.id, topic.id, %{body: "<p>a</p>"})
    {:ok, _} = Forum.save_draft(user.id, nil, %{body: "<p>b</p>"})
    {:ok, _} = Forum.save_draft(other.id, topic.id, %{body: "<p>c</p>"})

    assert Forum.count_drafts(user.id) == 2
    assert Forum.count_drafts(other.id) == 1
  end
end
