defmodule Colloq.Repo.Migrations.AlterPredictionColumnTypes do
  use Ecto.Migration

  def up do
    alter table(:predictions) do
      modify :fixture_id, :string
      modify :first_scorer, :string
      modify :motm, :string
    end
  end

  def down do
    alter table(:predictions) do
      modify :fixture_id, :integer
      modify :first_scorer, :integer
      modify :motm, :integer
    end
  end
end
