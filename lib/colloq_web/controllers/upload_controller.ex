defmodule ColloqWeb.UploadController do
  @moduledoc """
  Image uploads for the composer.

  In prod (R2 selected) files go to Cloudflare R2 via `Colloq.Media`; otherwise
  they're written under priv/static/uploads and served from a local web path,
  which keeps dev/test working without object-storage credentials.
  """
  use ColloqWeb, :controller

  alias Colloq.Media.Sniff

  @max_bytes 5_000_000
  @allowed ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    with {:ok, detected} <- validate(upload),
         {:ok, url} <- store(upload, detected) do
      json(conn, %{url: url})
    else
      {:error, msg} -> conn |> put_status(422) |> json(%{error: msg})
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "no file"})
  end

  # The client's `content_type` is not evidence of anything — it's a form field
  # the uploader controls. The file's own bytes decide what this is, and the
  # extension it gets stored under follows from that, so the two can no longer
  # disagree (a `.html` declared as `image/png` used to land in priv/static and
  # be served back as text/html).
  defp validate(%Plug.Upload{path: path}) do
    cond do
      File.stat!(path).size > @max_bytes ->
        {:error, "El archivo supera los 5 MB"}

      true ->
        case Sniff.detect(path) do
          {:ok, %{content_type: ct} = detected} when ct in @allowed -> {:ok, detected}
          _ -> {:error, "Tipo de archivo no permitido"}
        end
    end
  end

  defp store(%Plug.Upload{path: tmp}, %{ext: ext} = detected) do
    fname = "#{System.system_time(:millisecond)}-#{:rand.uniform(1_000_000)}#{ext}"

    if Application.get_env(:colloq, :media_storage) == Colloq.Media.R2 do
      # R2 serves objects straight from the CDN domain, where UploadHeaders
      # never runs — the disposition has to be baked into the object's metadata
      # at write time. The sandbox CSP still has to come from a Cloudflare
      # Transform Rule on that hostname.
      case Colloq.Media.upload(File.read!(tmp),
             filename: fname,
             content_type: detected.content_type,
             disposition: detected.disposition
           ) do
        {:ok, %{url: url}} -> {:ok, url}
        {:error, reason} -> {:error, "No se pudo subir el archivo: #{inspect(reason)}"}
      end
    else
      dir = Path.join(:code.priv_dir(:colloq), "static/uploads")
      File.mkdir_p!(dir)
      File.cp!(tmp, Path.join(dir, fname))
      {:ok, "/uploads/#{fname}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
