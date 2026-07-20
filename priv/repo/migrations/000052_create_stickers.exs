defmodule Colloq.Repo.Migrations.CreateStickers do
  use Ecto.Migration

  def change do
    create table(:sticker_packs) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :position, :integer, null: false, default: 0
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sticker_packs, [:slug])

    create table(:stickers) do
      add :pack_id, references(:sticker_packs, on_delete: :delete_all), null: false
      add :image_url, :string, null: false
      add :keywords, :string
      add :position, :integer, null: false, default: 0
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stickers, [:pack_id])
  end
end
