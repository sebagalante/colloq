defmodule Colloq.Media.Local do
  @moduledoc """
  Local filesystem storage adapter (testing).
  Writes to /tmp/colloq_uploads/. No HTTP calls.
  """
  @behaviour Colloq.Media
  @upload_dir "/tmp/colloq_uploads"

  def upload(data, opts) do
    filename = Keyword.get(opts, :filename, "#{System.unique_integer(:positive)}.bin")
    path = Path.join(@upload_dir, filename)

    with :ok <- File.mkdir_p!(@upload_dir) |> (fn _ -> :ok end).(),
         :ok <- File.write(path, data) do
      {:ok, %{url: "file://#{path}", filename: filename}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def delete(url, _opts) do
    case String.replace_prefix(url, "file://", "") do
      ^url -> {:error, :not_local_file}
      path -> File.rm(path)
    end
  end
end