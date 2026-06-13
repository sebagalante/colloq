defmodule Colloq.Workers.EmbedWorker do
  @moduledoc """
  Worker de unfurling de enlaces en posts.

  Extrae URLs del cuerpo del post, consulta metadatos Open Graph
  (og:title, og:description, og:image) vía fetch_embed/1 e inserta
  el registro Embed en base de datos.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum.Post

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Repo.get!(Post, post_id)
    urls = extract_urls(post.body)

    embeds =
      urls
      |> Enum.map(&fetch_embed/1)
      |> Enum.reject(&is_nil/1)

    # Insertar los embeds y asociarlos al post
    now = DateTime.utc_now()

    rows =
      Enum.map(embeds, fn embed ->
        %{
          post_id: post.id,
          url: embed.url,
          title: embed.title,
          description: embed.description,
          image_url: embed.image_url,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [] do
      Repo.insert_all("embeds", rows)
    end

    :ok
  end

  @doc """
  Extrae URLs del cuerpo HTML de un post.
  """
  def extract_urls(body) when is_binary(body) do
    ~r/href=["'](https?:\/\/[^"'\s]+)["']/
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.take(5)
  end

  @doc """
  Obtiene metadatos Open Graph de una URL.
  Retorna un mapa con los campos encontrados o nil si falla.
  """
  def fetch_embed(url) do
    case Req.get(url, max_redirects: 3, receive_timeout: 5_000) do
      {:ok, %{body: html}} ->
        %{
          url: url,
          title: extract_meta(html, "og:title") || extract_meta(html, "title") || "",
          description: extract_meta(html, "og:description") || extract_meta(html, "description") || "",
          image_url: extract_meta(html, "og:image") || ""
        }

      {:error, _} ->
        nil
    end
  end

  defp extract_meta(html, property) do
    pattern = ~r/<meta[^>]+property=["']#{Regex.escape(property)}["'][^>]+content=["']([^"']+)["']/i

    case Regex.run(pattern, html, capture: :all_but_first) do
      [content | _] -> String.trim(content)
      nil -> nil
    end
  end
end
