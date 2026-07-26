defmodule ColloqWeb.SearchApiTest do
  @moduledoc "JSON endpoint behind the header typeahead."
  use ColloqWeb.ConnCase
  import Colloq.Factory

  @endpoint ColloqWeb.Endpoint

  setup do
    category = insert(:category, name: "Racing Club")
    author = insert(:user)

    topic = insert(:topic, title: "Análisis del mediocampo", category: category, user: author)
    insert(:post, topic: topic, user: author, post_number: 1, body: "<p>Ganamos equilibrio</p>")

    %{category: category, topic: topic, author: author}
  end

  test "returns nothing below the minimum query length", %{conn: conn} do
    body = conn |> get("/api/search?q=m") |> json_response(200)

    assert body["topics"] == []
    assert body["posts"] == []
  end

  test "matches topics by title", %{conn: conn} do
    body = conn |> get("/api/search?q=mediocampo") |> json_response(200)

    assert [topic] = body["topics"]
    assert topic["title"] == "Análisis del mediocampo"
    assert topic["category"] == "Racing Club"
    assert topic["url"] =~ "/t/"
  end

  test "matches posts by body and deep-links to the comment", %{conn: conn} do
    body = conn |> get("/api/search?q=equilibrio") |> json_response(200)

    assert [post] = body["posts"]
    assert post["excerpt"] =~ "Ganamos equilibrio"
    # HTML is stripped from the excerpt, not passed through.
    refute post["excerpt"] =~ "<p>"

    # `?c=` roots the topic view at the comment. A bare "#post-N" fragment only
    # scrolls when the comment is on the first page, so on a long thread the
    # reader landed at the top with no indication why.
    assert post["url"] =~ ~r{/t/\d+\?c=\d+#post-\d+}
  end

  test "the linked comment is actually rendered on the page it points to", %{conn: conn} do
    topic = insert(:topic, category: insert(:category))
    author = insert(:user)

    insert(:post, topic: topic, user: author, post_number: 1, body: "<p>primero</p>")
    target = insert(:post, topic: topic, user: author, post_number: 2, body: "<p>pelota parada</p>")

    body = conn |> get("/api/search?q=pelota") |> json_response(200)
    assert [%{"url" => url}] = body["posts"]

    html = conn |> get(url) |> html_response(200)
    assert html =~ ~s(id="post-#{target.id}")
  end

  test "an empty query is handled without error", %{conn: conn} do
    body = conn |> get("/api/search") |> json_response(200)

    assert body["topics"] == []
    assert body["query"] == ""
  end

  test "works logged out", %{conn: conn} do
    body = conn |> get("/api/search?q=mediocampo") |> json_response(200)
    assert length(body["topics"]) == 1
  end

  describe "in this topic" do
    setup ctx do
      other = insert(:topic, title: "Otro tema", category: ctx.category, user: ctx.author)
      insert(:post, topic: other, user: ctx.author, post_number: 1, body: "<p>equilibrio en otro hilo</p>")
      Map.put(ctx, :other, other)
    end

    test "unscoped search finds matches in every topic", %{conn: conn} do
      body = conn |> get("/api/search?q=equilibrio") |> json_response(200)

      assert length(body["posts"]) == 2
      refute body["scoped"]
    end

    test "scoping to a topic returns only that thread's comments", ctx do
      %{conn: conn, topic: topic} = ctx

      body = conn |> get("/api/search?q=equilibrio&topic_id=#{topic.id}") |> json_response(200)

      assert body["scoped"]
      assert [post] = body["posts"]
      assert post["topic"] == topic.title
    end

    test "a scoped search drops the topic list", ctx do
      %{conn: conn, topic: topic} = ctx

      body = conn |> get("/api/search?q=mediocampo&topic_id=#{topic.id}") |> json_response(200)

      assert body["topics"] == [],
             "the reader already picked the thread; matching topic titles are noise"
    end

    test "a junk topic_id is ignored rather than returning nothing", %{conn: conn} do
      body = conn |> get("/api/search?q=equilibrio&topic_id=abc") |> json_response(200)

      refute body["scoped"]
      assert length(body["posts"]) == 2
    end
  end
end
