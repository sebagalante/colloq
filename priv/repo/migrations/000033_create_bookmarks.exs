defmodule Colloq.Repo.Migrations.CreateBookmarks do
  use Ecto.Migration

  def change do
    create table(:bookmarks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :post_id, references(:posts, on_delete: :delete_all), null: false
      add :topic_id, references(:topics, on_delete: :delete_all)
      add :note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:bookmarks, [:user_id])
    create index(:bookmarks, [:post_id])
    create unique_index(:bookmarks, [:user_id, :post_id])
  end
end
