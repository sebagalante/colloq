defmodule Colloq.Sofascore.SofascorePlayer do
  @moduledoc """
  Sofascore player schema.

  Stores Sofascore IDs and metadata for players
  across multiple teams.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sofascore_players" do
    field :sofascore_id, :string
    field :name, :string
    field :slug, :string
    field :team_id, :integer
    field :position, :string
    field :photo_url, :string
    field :transfermarkt_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(player, attrs) do
    player
    |> cast(attrs, [
      :sofascore_id, :name, :slug, :team_id, :position,
      :photo_url, :transfermarkt_id
    ])
    |> validate_required([:sofascore_id, :name])
    |> unique_constraint(:sofascore_id, name: :sofascore_players_sofascore_id_index)
    |> generate_slug()
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9\s-]/, "")
          |> String.replace(~r/\s+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
