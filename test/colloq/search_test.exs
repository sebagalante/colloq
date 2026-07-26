defmodule Colloq.SearchTest do
  @moduledoc """
  Full-text search over the `search_vector` generated columns.

  The cases that matter are the ones the previous `ILIKE '%term%'` version could
  not do at all — accent folding and stemming — plus the infix case it *could*
  do, which the ILIKE fallback still has to cover.
  """
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.Forum

  setup do
    category = insert(:category)
    author = insert(:user)

    topic =
      insert(:topic,
        title: "Análisis: el mediocampo de Racing",
        category: category,
        user: author
      )

    insert(:post,
      topic: topic,
      user: author,
      post_number: 1,
      body: "<p>Los goles llegaron en el segundo tiempo</p>"
    )

    %{topic: topic, category: category, author: author}
  end

  defp titles(results), do: Enum.map(results, & &1.title)

  describe "topics" do
    test "matches ignoring accents" do
      assert titles(Forum.search_topics("analisis")) == ["Análisis: el mediocampo de Racing"]
    end

    test "matches a word prefix" do
      assert length(Forum.search_topics("mediocamp")) == 1
    end

    test "falls back to a contains-match for infixes full text can't reach" do
      # "campo" is not a prefix of "mediocampo", so this can only come from the
      # ILIKE fallback.
      assert length(Forum.search_topics("campo")) == 1
    end

    test "requires every term to match" do
      assert Forum.search_topics("mediocampo boca") == []
    end

    test "a blank query returns nothing" do
      assert Forum.search_topics("") == []
      assert Forum.search_topics(nil) == []
    end

    test "tsquery operators in user input don't raise" do
      # Unsanitised, each of these is a syntax error inside to_tsquery/2.
      for input <- ["racing & independiente", "!racing", "racing | boca", "(racing", "a:*:*", "&&&"] do
        assert is_list(Forum.search_topics(input)), "raised on #{inspect(input)}"
      end
    end

    test "archived topics stay out of results" do
      insert(:topic, title: "Mediocampo archivado", archived: true)
      assert length(Forum.search_topics("mediocampo")) == 1
    end

    test "hidden categories are excluded" do
      %{id: hidden_id} = hidden = insert(:category)
      insert(:topic, title: "Mediocampo secreto", category: hidden)

      results = Forum.search_topics("mediocampo", hidden_category_ids: [hidden_id])

      refute "Mediocampo secreto" in titles(results)
    end
  end

  describe "posts" do
    test "stems Spanish word forms" do
      # The body says "goles"; searching the singular has to find it. This is
      # the case ILIKE could never handle.
      assert length(Forum.search_posts("gol")) == 1
    end

    test "searches the text, never the markup" do
      topic = insert(:topic, category: insert(:category))

      insert(:post,
        topic: topic,
        user: insert(:user),
        post_number: 1,
        body: ~s(<p><strong><a href="https://ejemplo.test">mirá esto</a></strong></p>)
      )

      # Markup tokens must find nothing, through the full-text path *and* the
      # contains-match fallback. Against the raw body these matched every post
      # in the forum.
      for markup <- ~w(strong href https ejemplo.test) do
        assert Forum.search_posts(markup) == [], "#{markup} matched the markup"
      end

      # The visible text still matches.
      assert length(Forum.search_posts("mirá")) == 1
    end

    test "hidden categories are excluded" do
      %{id: hidden_id} = hidden = insert(:category)
      topic = insert(:topic, category: hidden)
      insert(:post, topic: topic, user: insert(:user), post_number: 1, body: "<p>goles secretos</p>")

      results = Forum.search_posts("goles", hidden_category_ids: [hidden_id])

      assert length(results) == 1
      refute Enum.any?(results, &(&1.topic_id == topic.id))
    end
  end
end
