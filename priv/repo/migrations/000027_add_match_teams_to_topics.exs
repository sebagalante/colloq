defmodule Colloq.Repo.Migrations.AddMatchTeamsToTopics do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add_if_not_exists :home_team, :string
      add_if_not_exists :away_team, :string
    end
  end
end
