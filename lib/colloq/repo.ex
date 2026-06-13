defmodule Colloq.Repo do
  use Ecto.Repo,
    otp_app: :colloq,
    adapter: Ecto.Adapters.Postgres

  @moduledoc """
  Ecto repository for Colloq.
  
  Uses Postgres 17 with ParadeDB pg_search extension for BM25 search.
  """

  def init(type, config) do
    {:ok, Keyword.put(config, :url, System.get_env("DATABASE_URL"))}
  end
end
