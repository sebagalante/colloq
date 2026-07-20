defmodule Colloq.Workers.EmbedWorker do
  @moduledoc """
  Link unfurling worker for posts.

  Extracts URLs from the post body, fetches Open Graph metadata
  (og:title, og:description, og:image) via fetch_embed/1, and inserts
  the Embed record into the database.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  import Ecto.Query
  alias Colloq.Repo
  alias Colloq.Forum.Post

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    case Repo.get(Post, post_id) do
      nil ->
        :ok

      post ->
        now = DateTime.utc_now()

        rows =
          post.body
          |> extract_urls()
          |> Enum.map(fn url ->
            # Always create an embed per URL; enrich with Open Graph data when the
            # fetch succeeds. This keeps YouTube (rendered as an iframe from the URL)
            # and generic link cards working even if the site can't be scraped.
            og = fetch_embed(url) || %{}
            host = URI.parse(url).host

            %{
              post_id: post.id,
              url: url,
              host: host,
              title: present(og[:title]) || host || url,
              description: og[:description] || "",
              image_url: og[:image_url] || "",
              inserted_at: now,
              updated_at: now
            }
          end)

        if rows != [] do
          # Idempotent: replace any embeds from a previous run of this post.
          Repo.delete_all(from(e in "embeds", where: e.post_id == ^post.id))
          Repo.insert_all("embeds", rows)

          # Nudge open topic views to reload so the embeds appear without a manual refresh.
          ColloqWeb.Endpoint.broadcast("forum:topic:#{post.topic_id}", "new_post", %{
            post_id: post.id
          })
        end

        :ok
    end
  end

  defp present(s) when is_binary(s) and s != "", do: s
  defp present(_), do: nil

  @doc """
  Extrae URLs del cuerpo HTML de un post.
  """
  def extract_urls(body) when is_binary(body) do
    # Match any http(s) URL, whether bare in text or inside an href attribute.
    # We DO include URLs inside quotes (so quoted links still get a preview),
    # but strip <img> tags first: an inline image (e.g. a quoted image) already
    # renders itself and shouldn't also spawn a duplicate card.
    ~r{https?://[^\s"'<>]+}
    |> Regex.scan(strip_img_tags(body))
    |> List.flatten()
    |> Enum.map(&clean_url/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp strip_img_tags(body), do: String.replace(body, ~r/<img[^>]*>/i, "")

  # Trim trailing punctuation, keeping parens that belong to the URL (e.g.
  # Wikipedia "..._(Avellaneda)"). Drops a trailing ")" only when unbalanced.
  defp clean_url(url) do
    url = url |> decode_entities() |> String.replace(~r/[.,;:!?]+$/, "")

    if String.ends_with?(url, ")") and not String.contains?(url, "(") do
      String.trim_trailing(url, ")")
    else
      url
    end
  end

  defp strip_blockquotes(body) do
    String.replace(body, ~r"<blockquote.*?</blockquote>"s, "")
  end

  # A real browser user-agent — many news sites and CDNs return 403/406 to
  # obvious bot agents, which would leave every generic link with an empty card.
  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  @doc """
  Obtiene metadatos de una URL (Wikipedia REST API o, si no, Open Graph).
  Retorna un mapa con los campos encontrados o nil si falla.
  """
  def fetch_embed(url) do
    case wikipedia_summary(url) do
      nil -> fetch_og(url)
      summary -> summary
    end
  end

  # Wikipedia articles: use the REST summary API — it reliably returns a clean
  # extract + thumbnail for ANY article, which OG scraping often misses.
  defp wikipedia_summary(url) do
    with [_, lang, title] <-
           Regex.run(~r"https?://([a-z]{2,3})\.(?:m\.)?wikipedia\.org/wiki/([^?#]+)", url) do
      api = "https://#{lang}.wikipedia.org/api/rest_v1/page/summary/#{title}"

      case Req.get(api,
             receive_timeout: 6_000,
             connect_options: [timeout: 6_000],
             retry: false,
             headers: [{"user-agent", @user_agent}, {"accept", "application/json"}]
           ) do
        {:ok, %{status: 200, body: %{} = data}} ->
          %{
            url: url,
            title: present(data["title"]) || "Wikipedia",
            description: present(data["extract"]) || "",
            image_url: get_in(data, ["thumbnail", "source"]) || ""
          }

        _ ->
          nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_og(url) do
    case Req.get(url,
           max_redirects: 3,
           receive_timeout: 6_000,
           connect_options: [timeout: 6_000],
           retry: false,
           headers: [
             {"user-agent", @user_agent},
             {"accept", "text/html,application/xhtml+xml"}
           ]
         ) do
      {:ok, %{status: status, body: html}} when status < 400 and is_binary(html) ->
        %{
          url: url,
          title: extract_meta(html, "og:title") || extract_title_tag(html) || "",
          description:
            extract_meta(html, "og:description") || extract_meta(html, "description") || "",
          image_url: absolute_image(extract_meta(html, "og:image"), url)
        }

      _ ->
        nil
    end
  rescue
    # Req can raise on TLS/DNS/pool errors — treat any failure as "no preview".
    _ -> nil
  end

  # Match a <meta> tag by og:/name property in EITHER attribute order
  # (content before or after the property/name attribute).
  defp extract_meta(html, property) do
    esc = Regex.escape(property)

    forward = ~r/<meta[^>]+(?:property|name)=["']#{esc}["'][^>]*?content=["']([^"']*)["']/i
    reverse = ~r/<meta[^>]+content=["']([^"']*)["'][^>]*?(?:property|name)=["']#{esc}["']/i

    with nil <- run_meta(html, forward),
         nil <- run_meta(html, reverse) do
      nil
    end
  end

  defp run_meta(html, pattern) do
    case Regex.run(pattern, html, capture: :all_but_first) do
      [content | _] -> present_decoded(content)
      _ -> nil
    end
  end

  defp extract_title_tag(html) do
    case Regex.run(~r/<title[^>]*>([^<]*)<\/title>/i, html, capture: :all_but_first) do
      [content | _] -> present_decoded(content)
      _ -> nil
    end
  end

  defp present_decoded(content) do
    decoded = content |> decode_entities() |> String.trim()
    if decoded == "", do: nil, else: decoded
  end

  @doc """
  Decode the HTML entities that appear in scraped titles and in URLs pulled
  out of a post body.

  This existed for titles but was never applied to the URL itself. Post bodies
  are HTML, so a link written as `?t=70&v=X` is stored as `?t=70&amp;v=X`, and
  the extractor scanned that markup directly — the embed ended up pointing at a
  *different*, broken URL, with YouTube receiving a parameter named `amp;v`.

  `&amp;` is unescaped last so `&amp;lt;` decodes to `&lt;`, not `<`.
  """
  def decode_entities(text) when is_binary(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#34;", "\"")
    |> String.replace(~r/&#0?39;|&apos;|&#x27;/i, "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace("&#38;", "&")
    |> String.replace("&amp;", "&")
  end

  def decode_entities(text), do: text

  # Resolve protocol-relative or root-relative og:image URLs against the page URL.
  defp absolute_image(nil, _base), do: ""
  defp absolute_image("", _base), do: ""

  defp absolute_image(image, base) do
    case URI.merge(URI.parse(base), image) do
      %URI{} = uri -> URI.to_string(uri)
      _ -> image
    end
  rescue
    _ -> image
  end
end
