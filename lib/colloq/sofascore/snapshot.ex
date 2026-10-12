defmodule Colloq.Sofascore.Snapshot do
  @moduledoc """
  Last successful Sofascore response for one API path, kept in the database so
  the calendar survives both a server restart and Sofascore refusing requests.
  """
  use Ecto.Schema

  schema "sofascore_snapshots" do
    field :path, :string
    field :body, :map
    field :fetched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
