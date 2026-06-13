defmodule Colloq.Repo.Migrations.CreateSiteSettings do
  use Ecto.Migration

  def change do
    create table(:site_settings) do
      add :key, :string, null: false
      add :value, :text
      add :type, :string, default: "string"  # string | integer | boolean | json | secret
      add :group, :string, default: "general"
      add :description, :text
      add :public, :boolean, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:site_settings, [:key])
    create index(:site_settings, [:group])
  end
end
