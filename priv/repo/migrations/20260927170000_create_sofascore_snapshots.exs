defmodule Colloq.Repo.Migrations.CreateSofascoreSnapshots do
  use Ecto.Migration

  # Last good response per Sofascore calendar endpoint. Cachex is in-memory, so a
  # restart while Sofascore is refusing us (403 by IP) left the Prode with no
  # fixtures at all; this is what the calendar falls back to instead.
  def change do
    create table(:sofascore_snapshots) do
      add :path, :string, null: false
      add :body, :map, null: false
      add :fetched_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sofascore_snapshots, [:path])
  end
end
