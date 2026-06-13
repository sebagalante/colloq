defmodule Colloq.Media do
  @moduledoc """
  Media storage behaviour and runtime dispatch.
  
  Swappable by env:
  - Dev  → Colloq.Media.Imgbb (1h auto-expiry, free at imgbb.com)
  - Prod → Colloq.Media.Bunny (BunnyCDN storage zone)
  - Test → Colloq.Media.Local (/tmp writes, no HTTP)
  """

  @callback upload(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}

  def upload(data, opts \\ []) do
    adapter = Application.get_env(:colloq, :media_storage, Colloq.Media.Local)
    adapter.upload(data, opts)
  end

  def delete(url, opts \\ []) do
    adapter = Application.get_env(:colloq, :media_storage, Colloq.Media.Local)
    adapter.delete(url, opts)
  end
end