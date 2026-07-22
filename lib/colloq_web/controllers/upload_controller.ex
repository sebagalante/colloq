defmodule ColloqWeb.UploadController do
  @moduledoc """
  Image uploads for the composer and chat attachments.

  In prod (R2 selected) files go to Cloudflare R2 via `Colloq.Media`; otherwise
  they're written under priv/static/uploads and served from a local web path,
  which keeps dev/test working without object-storage credentials.
  """
  use ColloqWeb, :controller

  @max_bytes 5_000_000
  @allowed ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    with :ok <- validate(upload),
         {:ok, url} <- store(upload) do
      json(conn, %{url: url})
    else
      {:error, msg} -> conn |> put_status(422) |> json(%{error: msg})
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "no file"})
  end

  @attachment_max_bytes 15_000_000

  @doc """
  Chat attachment upload — accepts any file type (up to 15 MB) and returns
  its URL, original name and content type.
  """
  def attachment(conn, %{"file" => %Plug.Upload{} = upload}) do
    cond do
      File.stat!(upload.path).size > @attachment_max_bytes ->
        conn |> put_status(422) |> json(%{error: "El archivo supera los 15 MB"})

      true ->
        case store(upload) do
          {:ok, url} ->
            json(conn, %{url: url, name: upload.filename, type: upload.content_type})

          {:error, msg} ->
            conn |> put_status(422) |> json(%{error: msg})
        end
    end
  end

  def attachment(conn, _params) do
    conn |> put_status(400) |> json(%{error: "no file"})
  end

  defp validate(%Plug.Upload{content_type: ct, path: path}) do
    cond do
      ct not in @allowed -> {:error, "Tipo de archivo no permitido"}
      File.stat!(path).size > @max_bytes -> {:error, "El archivo supera los 5 MB"}
      true -> :ok
    end
  end

  defp store(%Plug.Upload{path: tmp, filename: name} = upload) do
    ext = name |> Path.extname() |> String.downcase()
    fname = "#{System.system_time(:millisecond)}-#{:rand.uniform(1_000_000)}#{ext}"

    if Application.get_env(:colloq, :media_storage) == Colloq.Media.R2 do
      case Colloq.Media.upload(File.read!(tmp),
             filename: fname,
             content_type: upload.content_type
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
