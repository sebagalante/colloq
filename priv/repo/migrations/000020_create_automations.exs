defmodule Colloq.Repo.Migrations.CreateAutomations do
  use Ecto.Migration

  def change do
    create table(:automations) do
      add :name, :string, null: false
      add :enabled, :boolean, default: true
      add :trigger, :string
      add :trigger_config, :map, default: %{}
      add :script, :string
      add :script_config, :map, default: %{}
      add :last_run_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:automations, [:enabled])
    create index(:automations, [:trigger])
  end
end
