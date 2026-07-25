defmodule Colloq.Repo.Migrations.AddJerseyNumberToSofascorePlayers do
  use Ecto.Migration

  def change do
    alter table(:sofascore_players) do
      add :jersey_number, :integer
    end
  end
end
