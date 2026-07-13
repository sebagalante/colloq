defmodule Colloq.Media.Bunny do
  @moduledoc """
  BunnyCDN storage adapter (production).
  Requires BUNNY_API_KEY and BUNNY_STORAGE_ZONE env vars.
  """
  @behaviour Colloq.Media

  @storage_base "https://storage.bunnycdn.com"

  def upload(_data, _opts) do
    {:error, :not_implemented}
    # TODO: POST to #{storage_url()}/{storage_zone}/{path}
    #        headers: [{"AccessKey", key}, {"Content-Type", content_type}]
  end

  def delete(_url, _opts) do
    {:error, :not_implemented}
  end

  defp storage_url, do: Application.get_env(:colloq, :bunny_storage_url, @storage_base)
end