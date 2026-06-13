defmodule Colloq.Repo.Migrations.CreatePredictions do
  use Ecto.Migration

  def change do
    create table(:predictions) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :fixture_id, :integer
      add :home_score, :integer
      add :away_score, :integer
      add :first_scorer, :integer
      add :motm, :integer
      add :points, :integer
      add :scored_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:predictions, [:user_id, :fixture_id])
  end
end
