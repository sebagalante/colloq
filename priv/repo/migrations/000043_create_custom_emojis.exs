defmodule Colloq.Repo.Migrations.CreateCustomEmojis do
  use Ecto.Migration

  def change do
    create table(:custom_emojis) do
      add :name, :string, null: false
      add :image_url, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:custom_emojis, [:name])
  end
end
