defmodule Colloq.Repo.Migrations.CreatePostDrafts do
  use Ecto.Migration

  def change do
    create table(:post_drafts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :nilify_all)
      add :topic_id, references(:topics, on_delete: :nilify_all)
      add :title, :string
      add :body, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:post_drafts, [:user_id])
    create index(:post_drafts, [:inserted_at])
  end
end
