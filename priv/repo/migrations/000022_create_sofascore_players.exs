defmodule Colloq.Repo.Migrations.CreateSofascorePlayers do
  use Ecto.Migration

  def change do
    create table(:sofascore_players) do
      add :sofascore_id, :string, null: false
      add :name, :string
      add :slug, :string
      add :team_id, :integer
      add :position, :string
      add :photo_url, :string
      add :transfermarkt_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sofascore_players, [:sofascore_id])
    create index(:sofascore_players, [:team_id])
  end
end
