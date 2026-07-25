defmodule Colloq.Repo do
  use Ecto.Repo,
    otp_app: :colloq,
    adapter: Ecto.Adapters.Postgres

  @moduledoc """
  Ecto repository for Colloq. Standard Postgres — search uses basic `ILIKE`
  (see `Colloq.Forum.search_topics/2` and `search_posts/2`).
  """

  @doc """
  Applies `DATABASE_URL` at repo start, when it is actually set.

  Two things this must NOT do, both of which it used to:

  1. Put `url: nil` when the var is unset — that overrode the host/database
     from config and left the repo with nothing to connect to (`mix test` died
     in `ecto.create` with "key :database not found").
  2. Point the test suite at a non-test database. The `dotenv` dep is loaded in
     `:test` too, so `.env` — with the *development* `DATABASE_URL` — is in the
     environment by the time the repo starts. Tests would then run against the
     dev database; only Ecto's sandbox rollbacks kept that from destroying data.
     The sandbox pool is configured in `config/test.exs` alone, so it's a
     reliable "this is the test run" signal: under it, a `DATABASE_URL` that
     doesn't name a `*_test` database is ignored in favour of the test config.
     CI can still point the suite anywhere, as long as the name says `_test`.
  """
  def init(_type, config) do
    case System.get_env("DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        if usable_url?(url, config), do: {:ok, Keyword.put(config, :url, url)}, else: {:ok, config}

      _ ->
        {:ok, config}
    end
  end

  defp usable_url?(url, config) do
    if config[:pool] == Ecto.Adapters.SQL.Sandbox do
      database = url |> URI.parse() |> Map.get(:path) |> to_string() |> String.trim_leading("/")
      String.ends_with?(database, "_test") or String.contains?(database, "_test")
    else
      true
    end
  end
end
