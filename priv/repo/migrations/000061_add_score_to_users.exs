defmodule Colloq.Repo.Migrations.AddScoreToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Gamification score: engagement points (posting, likes, visiting),
      # recomputed periodically by Colloq.Workers.ScoreWorker. Denormalised so
      # the leaderboard is a cheap ordered read.
      add :score, :integer, null: false, default: 0
      add :score_updated_at, :utc_datetime_usec
    end

    # Leaderboard reads order by score descending.
    create index(:users, [:score])
  end
end
