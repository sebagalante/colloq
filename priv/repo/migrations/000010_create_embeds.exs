defmodule Colloq.Repo.Migrations.CreateEmbeds do
  use Ecto.Migration

  def change do
    create table(:embeds) do
      add :url, :string, null: false
      add :host, :string, null: false
      add :title, :string
      add :description, :text
      add :image_url, :string
      add :author, :string
      add :published_at, :utc_datetime_usec
      add :html, :text
      add :click_count, :integer, default: 0

      add :post_id, references(:posts, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:embeds, [:url])
    create index(:embeds, [:post_id])
  end
end
