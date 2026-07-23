defmodule Colloq.Repo.Migrations.AddSeasonRoundToPredictions do
  use Ecto.Migration

  # The fecha-based model ties every prediction to a Sofascore league round.
  # `fixture_id` is the Sofascore *event id* (a string); `season_id` and `round`
  # let the leaderboard scope by season and per-fecha without parsing ids.
  def change do
    alter table(:predictions) do
      add :season_id, :integer
      add :round, :integer
    end

    create index(:predictions, [:season_id, :round])
  end
end
