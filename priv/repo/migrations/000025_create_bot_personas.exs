defmodule Colloq.Repo.Migrations.CreateBotPersonas do
  use Ecto.Migration

  def change do
    create table(:bot_personas) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :avatar_url, :string
      add :description, :text
      add :system_prompt, :text
      add :provider, :string
      add :model, :string
      add :temperature, :float, default: 0.7
      add :max_tokens, :integer, default: 512
      add :enabled, :boolean, default: true
      add :trigger_on_mention, :boolean, default: true
      add :trigger_categories, {:array, :integer}
      add :allowed_trust_level, :integer, default: 0
      add :rate_limit_per_user, :integer, default: 10
      add :managed_by_worker, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bot_personas, [:slug])
  end
end
