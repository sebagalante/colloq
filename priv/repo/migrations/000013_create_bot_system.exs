defmodule Colloq.Repo.Migrations.CreateBotSystem do
  use Ecto.Migration

  def change do
    create table(:bot_system) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :type, :string, null: false  # "system" | "persona"
      add :active, :boolean, default: true
      add :api_key, :string
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bot_system, [:slug])
  end
end
