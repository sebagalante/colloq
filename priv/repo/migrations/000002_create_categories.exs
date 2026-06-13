defmodule Colloq.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :color, :string, default: "#3b82f6"
      add :icon, :string
      add :position, :integer, default: 0
      add :topic_count, :integer, default: 0
      add :post_count, :integer, default: 0

      # Permissions
      add :read_restricted, :boolean, default: false
      add :write_restricted, :boolean, default: false
      add :required_trust_level, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:categories, [:slug])
    create index(:categories, [:position])
  end
end
