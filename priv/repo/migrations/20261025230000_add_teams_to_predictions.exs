defmodule Colloq.Repo.Migrations.AddTeamsToPredictions do
  use Ecto.Migration

  # The Prode can read its fechas from Sofascore or FotMob, whose match ids have
  # nothing in common. Storing the teams lets a prediction find its match again
  # after the data source is switched. Older rows stay null and only match by id.
  def change do
    alter table(:predictions) do
      add :home_team, :string
      add :away_team, :string
    end
  end
end
