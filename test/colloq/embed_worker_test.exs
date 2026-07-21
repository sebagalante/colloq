defmodule Colloq.EmbedWorkerTest do
  use ExUnit.Case, async: true

  alias Colloq.Workers.EmbedWorker

  describe "extract_urls/1 with @mentions" do
    test "an @mention does not produce a preview card" do
      # The composer stores mentions as absolute links to our own profile page,
      # which used to be unfurled into a "localhost · @cocobot · Colloq" card.
      body = ~s(<p><a href="http://localhost:4000/u/cocobot"><strong>@cocobot</strong></a> hola</p>)

      assert EmbedWorker.extract_urls(body) == []
    end

    test "a mention alongside a real link keeps only the real link" do
      body =
        ~s(<a href="http://localhost:4000/u/cocobot">@cocobot</a> mirá https://example.com/x)

      assert EmbedWorker.extract_urls(body) == ["https://example.com/x"]
    end

    test "an internal topic link still gets a card" do
      body = ~s(<p>Mirá http://localhost:4000/t/54 esto</p>)

      assert EmbedWorker.extract_urls(body) == ["http://localhost:4000/t/54"]
    end

    test "another site's /u/ path is unaffected" do
      body = ~s(<p>Perfil https://github.com/u/someone acá</p>)

      assert EmbedWorker.extract_urls(body) == ["https://github.com/u/someone"]
    end

    test "external links still get cards" do
      body = ~s(<p>Fuente https://onefootball.com/es/nota acá</p>)

      assert EmbedWorker.extract_urls(body) == ["https://onefootball.com/es/nota"]
    end
  end

  describe "extract_urls/1 deduplication" do
    test "a composer link is not unfurled twice" do
      # Tiptap stores the canonical href but renders the anchor text without
      # the trailing slash, so the same page appeared as two URLs and produced
      # two embeds — the second an empty card titled with the bare host.
      body =
        ~s(<p><a href="https://letterboxd.com/film/the-odyssey-2026/">https://letterboxd.com/film/the-odyssey-2026</a></p>)

      assert EmbedWorker.extract_urls(body) == ["https://letterboxd.com/film/the-odyssey-2026/"]
    end

    test "the canonical href is kept, not the bare text" do
      # The href is the version that actually serves OG tags.
      [url] =
        EmbedWorker.extract_urls(
          ~s(<a href="https://example.com/page/">https://example.com/page</a>)
        )

      assert String.ends_with?(url, "/page/")
    end

    test "different pages are still unfurled separately" do
      body = ~s(<p>https://example.com/a and https://example.com/b</p>)

      assert EmbedWorker.extract_urls(body) ==
               ["https://example.com/a", "https://example.com/b"]
    end

    test "query strings distinguish pages" do
      body = ~s(<p>https://example.com/p?id=1 and https://example.com/p?id=2</p>)

      assert length(EmbedWorker.extract_urls(body)) == 2
    end
  end

  describe "non-UTF8 metadata from remote sites" do
    # cmtv.com.ar serves Latin-1. Those bytes are not valid UTF-8, so inserting
    # the scraped title raised Postgrex 22021 (character_not_in_repertoire), the
    # job burned all three attempts, and the post silently got no preview card.
    test "Latin-1 bytes are converted rather than crashing the insert" do
      latin1 = <<"Garc", 0xED, "a / Aznar">>

      refute String.valid?(latin1)

      converted = :unicode.characters_to_binary(latin1, :latin1, :utf8)

      assert String.valid?(converted)
      assert converted == "García / Aznar"
    end

    test "bytes that are not Latin-1 either are stripped, not raised on" do
      garbage = <<0xFF, 0xFE, "hola">>

      cleaned =
        if String.valid?(garbage) do
          garbage
        else
          case :unicode.characters_to_binary(garbage, :latin1, :utf8) do
            c when is_binary(c) -> c
            _ -> garbage |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
          end
        end

      assert String.valid?(cleaned)
    end
  end
end
