defmodule Colloq.Media.Imgbb do
  @moduledoc """
  ImgBB storage adapter (development).
  Free tier — images auto-expire after 1 hour. Requires IMGBB_API_KEY.
  """
  @behaviour Colloq.Media

  def upload(_data, _opts) do
    {:error, :not_implemented}
    # TODO: POST to api.imgbb.com/1/upload
    #        form: [key: key, image: base64_data, expiration: 3600]
  end

  def delete(_url, _opts) do
    {:error, :not_implemented}
  end
end