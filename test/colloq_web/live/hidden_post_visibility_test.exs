defmodule ColloqWeb.HiddenPostVisibilityTest do
  @moduledoc """
  A post hidden by moderation must not leak its text anywhere.

  Every post *query* filters `deleted_at`, but the topic list preloads
  `first_post` through a belongs_to on `first_post_id`, which can't filter — so
  the front page kept printing the body of a post the topic page had already
  stopped serving.
  """
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.{Forum, Moderation, Repo}

  @endpoint ColloqWeb.Endpoint
  @secret "ESTETEXTONODEBERIAVERSE"

  setup do
    category = insert(:category)
    author = insert(:user, trust_level: 2)

    topic = insert(:topic, title: "Un tema cualquiera", category: category, user: author)
    op = insert(:post, topic: topic, user: author, post_number: 1, body: "<p>#{@secret}</p>")

    # first_post_id is what the topic list preloads for the excerpt.
    topic = topic |> Ecto.Changeset.change(first_post_id: op.id) |> Repo.update!()

    %{topic: topic, op: op, author: author, category: category}
  end

  test "the excerpt disappears from the topic list once the post is hidden", ctx do
    %{conn: conn, op: op} = ctx

    html = conn |> get("/") |> html_response(200)
    assert html =~ @secret, "precondition: a visible post shows its excerpt"

    {:ok, _} = Moderation.hide_post(op)

    html = conn |> get("/") |> html_response(200)
    refute html =~ @secret, "a hidden post must not leak its body into the topic list"
  end

  test "the topic page serves no hidden posts", ctx do
    %{op: op, topic: topic} = ctx

    {:ok, _} = Moderation.hide_post(op)

    {posts, _has_more} = Forum.list_root_posts(topic.id, MapSet.new(), 20, 0)

    assert posts == []
  end

  test "restoring the post brings the excerpt back", ctx do
    %{conn: conn, op: op} = ctx

    {:ok, hidden} = Moderation.hide_post(op)
    refute conn |> get("/") |> html_response(200) =~ @secret

    {:ok, _} = Moderation.restore_post(hidden)

    assert conn |> get("/") |> html_response(200) =~ @secret
  end

  test "a user's own deletion also stops leaking the excerpt", ctx do
    %{conn: conn, op: op, author: author} = ctx

    # Self-deletion sets deleted_at with hidden: false — a different path to the
    # same requirement.
    {:ok, _} = Forum.delete_post(op, author)

    refute conn |> get("/") |> html_response(200) =~ @secret
  end

  describe "the topic goes with its opening post" do
    test "hiding the opening post removes the topic from the front page", ctx do
      %{conn: conn, op: op, topic: topic} = ctx

      assert conn |> get("/") |> html_response(200) =~ topic.title

      {:ok, _} = Moderation.hide_post(op)

      html = conn |> get("/") |> html_response(200)
      refute html =~ topic.title, "a topic whose opening post was hidden must not stay listed"
      refute html =~ @secret
    end

    test "and from search", ctx do
      %{op: op, topic: topic} = ctx

      assert Enum.any?(Forum.search_topics(topic.title), &(&1.id == topic.id))

      {:ok, _} = Moderation.hide_post(op)

      refute Enum.any?(Forum.search_topics(topic.title), &(&1.id == topic.id))
    end

    test "hiding a reply leaves the topic alone", ctx do
      %{conn: conn, topic: topic, author: author} = ctx

      reply = insert(:post, topic: topic, user: author, post_number: 2, body: "<p>una respuesta</p>")

      {:ok, _} = Moderation.hide_post(reply)

      assert conn |> get("/") |> html_response(200) =~ topic.title,
             "hiding one reply must not take the whole thread down"

      assert Repo.get(Forum.Topic, topic.id).deleted_at == nil
    end

    test "restoring the opening post brings the topic back", ctx do
      %{conn: conn, op: op, topic: topic} = ctx

      {:ok, hidden} = Moderation.hide_post(op)
      refute conn |> get("/") |> html_response(200) =~ topic.title

      {:ok, _} = Moderation.restore_post(hidden)

      html = conn |> get("/") |> html_response(200)
      assert html =~ topic.title
      assert html =~ @secret
      assert Repo.get(Forum.Topic, topic.id).deleted_at == nil
    end

    test "a spam topic caught by its title disappears entirely", ctx do
      %{conn: conn, category: category} = ctx

      Colloq.SiteSettings.put("blocked_words", "viagra", type: "string", group: "forum")
      insert(:user, username: "sistema")
      spammer = insert(:user, trust_level: 1)

      {:ok, spam} =
        Forum.create_topic(spammer, %{
          "title" => "COMPRA VIAGRA BARATO",
          "body" => "<p>hola</p>",
          "category_id" => category.id
        })

      # Oban runs inline in test, so creation alone screens and hides it.
      html = conn |> get("/") |> html_response(200)

      refute html =~ "VIAGRA", "the spam title must not survive on the front page"
      assert Repo.get(Forum.Topic, spam.id).deleted_at
    end
  end

  describe "deleting a post does not advertise an update" do
    test "no banner appears when a post is deleted", ctx do
      %{conn: conn, topic: topic, author: author} = ctx

      reply = insert(:post, topic: topic, user: author, post_number: 2, body: "<p>una respuesta</p>")

      conn = Plug.Test.init_test_session(conn, %{"user_id" => author.id})
      {:ok, view, _html} = live(conn, "/")

      {:ok, _} = Forum.delete_post(reply, author)
      :timer.sleep(60)

      html = render(view)

      # "Ver N temas nuevos/actualizados" sends the reader to look at something.
      # A deletion has nothing to look at.
      refute html =~ "Ver 1", "a deletion must not be announced as an update"
    end

    test "a new reply still does announce one", ctx do
      %{conn: conn, topic: topic, author: author} = ctx

      conn = Plug.Test.init_test_session(conn, %{"user_id" => author.id})
      {:ok, view, _html} = live(conn, "/")

      {:ok, _} = Forum.create_post(topic, author, %{"body" => "<p>algo nuevo</p>"})
      :timer.sleep(60)

      assert render(view) =~ "Ver 1", "a real reply should still raise the banner"
    end
  end

  describe "live row refresh stays in its lane" do
    test "deleting a post in an off-page topic doesn't inject its row", ctx do
      %{conn: conn, author: author, category: category} = ctx

      old = DateTime.add(DateTime.utc_now(), -60, :day)
      buried = insert(:topic, title: "TEMA ENTERRADO", category: category, user: author,
                      bumped_at: old, inserted_at: old)
      op = insert(:post, topic: buried, user: author, post_number: 1, body: "<p>op</p>", inserted_at: old)
      reply = insert(:post, topic: buried, user: author, post_number: 2, body: "<p>x</p>", inserted_at: old)
      Repo.update!(Ecto.Changeset.change(buried, first_post_id: op.id, last_post_id: reply.id))

      # Push it well past the first page (@per_page is 20).
      for i <- 1..25 do
        t = insert(:topic, title: "Relleno #{i}", category: category, user: author)
        insert(:post, topic: t, user: author, post_number: 1, body: "<p>hola</p>")
      end

      conn = Plug.Test.init_test_session(conn, %{"user_id" => author.id})
      {:ok, view, html} = live(conn, "/")
      refute html =~ "TEMA ENTERRADO", "precondition: the topic is off-page"

      {:ok, _} = Forum.delete_post(reply, author)
      :timer.sleep(80)

      refute render(view) =~ "TEMA ENTERRADO",
             "a row the reader never had must not appear because a post was deleted in it"
    end
  end
end
