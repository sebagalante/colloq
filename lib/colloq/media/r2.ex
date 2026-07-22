defmodule Colloq.Media.R2 do
  @moduledoc """
  Cloudflare R2 storage adapter (production).

  R2 speaks the S3 API, so uploads/deletes go through `ex_aws_s3` (which handles
  SigV4 signing). Objects are served from a **custom domain** bound to the
  bucket, not the S3 endpoint — the S3 host is only used for writes.

  ## Config (set in runtime.exs from env)

    * `config :ex_aws` — `access_key_id`, `secret_access_key`, `region: "auto"`
    * `config :ex_aws, :s3` — `host: "<account>.r2.cloudflarestorage.com"`,
      `scheme: "https://"`
    * `config :colloq, Colloq.Media.R2` — `bucket:` and `public_base_url:`
      (the custom domain, e.g. "https://cdn.example.com")

  `upload/2` returns `{:ok, %{url: public_url, filename: key}}`; the stored url
  is the public custom-domain url, which is what the rest of the app renders.
  """
  @behaviour Colloq.Media

  require Logger

  @impl Colloq.Media
  def upload(data, opts) when is_binary(data) do
    filename = Keyword.get(opts, :filename) || default_filename()
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    bucket()
    |> ExAws.S3.put_object(filename, data, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, %{status_code: status}} when status in 200..299 ->
        {:ok, %{url: public_url(filename), filename: filename}}

      {:ok, resp} ->
        Logger.error("[R2] Unexpected upload status: #{inspect(resp)}")
        {:error, {:unexpected_status, resp}}

      {:error, reason} ->
        Logger.error("[R2] Upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Colloq.Media
  def delete(url, _opts) when is_binary(url) do
    case key_from_url(url) do
      {:ok, key} ->
        bucket()
        |> ExAws.S3.delete_object(key)
        |> ExAws.request()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      # A url that isn't under our public base isn't ours to delete (e.g. an
      # externally hosted avatar) — treat as a no-op rather than an error.
      :error ->
        {:error, :not_r2_url}
    end
  end

  # --- config helpers --------------------------------------------------------

  defp bucket, do: config!(:bucket)

  # Custom-domain base for serving, with any trailing slash trimmed so joins are
  # predictable.
  defp public_base, do: config!(:public_base_url) |> String.trim_trailing("/")

  defp public_url(key), do: "#{public_base()}/#{key}"

  # Recover the object key from a stored public url. Only urls under our own
  # base can be mapped back to a key; anything else returns :error.
  defp key_from_url(url) do
    base = public_base() <> "/"

    case String.starts_with?(url, base) do
      true -> {:ok, String.replace_prefix(url, base, "")}
      false -> :error
    end
  end

  defp default_filename, do: "#{System.unique_integer([:positive])}.bin"

  defp config!(key) do
    Application.get_env(:colloq, __MODULE__, [])
    |> Keyword.fetch!(key)
  end
end
