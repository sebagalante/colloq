defmodule ColloqWeb.PostRenderingTest do
  use Colloq.DataCase, async: false

  alias ColloqWeb.ForumLive.Topic

  defp hrefs(body) do
    body
    |> Topic.render_body()
    |> Phoenix.HTML.safe_to_string()
    |> then(&Regex.scan(~r/href="([^"]+)"/, &1))
    |> Enum.map(fn [_, href] -> href end)
  end

  describe "autolink trailing punctuation" do
    test "a URL ending a sentence does not capture the period" do
      assert hrefs("Mirá https://example.com/pagina.") == ["https://example.com/pagina"]
    end

    test "a URL inside parentheses does not capture the closing paren" do
      assert hrefs("Fuente (https://example.com/nota) confirmada.") ==
               ["https://example.com/nota"]
    end

    test "markdown link syntax from LLM bots yields a working href" do
      # The bots emit [label](url); the closing paren used to land in the href,
      # producing a 404 link on every citation.
      assert hrefs("Ver [onefootball.com](https://onefootball.com/es/bundesliga) acá.") ==
               ["https://onefootball.com/es/bundesliga"]
    end

    test "balanced parens inside a URL are preserved" do
      assert hrefs("Ver https://es.wikipedia.org/wiki/Estadio_(Boca) ahora.") ==
               ["https://es.wikipedia.org/wiki/Estadio_(Boca)"]
    end

    test "commas between URLs are not captured" do
      assert hrefs("Acá https://example.com/a, y acá https://example.com/b.") ==
               ["https://example.com/a", "https://example.com/b"]
    end

    test "a query string is left intact" do
      assert hrefs("Simple https://example.com/path?x=1") == ["https://example.com/path?x=1"]
    end

    test "a trailing question mark in prose is not part of the URL" do
      assert hrefs("¿Viste https://example.com/nota?") == ["https://example.com/nota"]
    end
  end
end
