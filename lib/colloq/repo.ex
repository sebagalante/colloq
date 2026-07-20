defmodule Colloq.Repo do
  use Ecto.Repo,
    otp_app: :colloq,
    adapter: Ecto.Adapters.Postgres

  @moduledoc """
  Ecto repository for Colloq. Standard Postgres — search uses basic `ILIKE`
  (see `Colloq.Forum.search_topics/2` and `search_posts/2`).
  """

  def init(type, config) do
    {:ok, Keyword.put(config, :url, System.get_env("DATABASE_URL"))}
  end
end
