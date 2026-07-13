defmodule Colloq.Repo.Migrations.CreateTags do
  use Ecto.Migration

  def change do
    create table(:tags) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :color, :string, default: "#6b7280"
      add :topic_count, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tags, [:slug])
    create unique_index(:tags, [:name])

    create table(:topic_tags) do
      add :topic_id, references(:topics, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:topic_tags, [:topic_id])
    create index(:topic_tags, [:tag_id])
    create unique_index(:topic_tags, [:topic_id, :tag_id])
  end
end
