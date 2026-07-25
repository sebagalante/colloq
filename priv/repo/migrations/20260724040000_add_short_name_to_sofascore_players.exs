defmodule Colloq.Repo.Migrations.AddShortNameToSofascorePlayers do
  use Ecto.Migration

  def change do
    alter table(:sofascore_players) do
      # Pitch label: the compound surname ("Di Cesare") or an explicit override
      # ("S. Sosa"). Nil falls back to the last word of the full name.
      add :short_name, :string
    end
  end
end
