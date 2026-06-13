defmodule Colloq.Media.Bunny do
  @moduledoc """
  BunnyCDN storage adapter (production).
  Requires BUNNY_API_KEY and BUNNY_STORAGE_ZONE env vars.
  """
  @behaviour Colloq.Media

  def upload(_data, _opts) do
    {:error, :not_implemented}
    # TODO: POST to https://storage.bunnycdn.com/{storage_zone}/{path}
    #        headers: [{"AccessKey", key}, {"Content-Type", content_type}]
  end

  def delete(_url, _opts) do
    {:error, :not_implemented}
  end
end