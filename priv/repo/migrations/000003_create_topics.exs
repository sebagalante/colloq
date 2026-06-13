defmodule Colloq.Repo.Migrations.CreateTopics do
  use Ecto.Migration

  def change do
    create table(:topics) do
      add :title, :string, null: false
      add :slug, :string, null: false
      add :raw_title, :string

      # Counters
      add :posts_count, :integer, default: 0
      add :views_count, :integer, default: 0
      add :likes_count, :integer, default: 0

      # States
      add :pinned, :boolean, default: false
      add :pinned_at, :utc_datetime_usec
      add :closed, :boolean, default: false
      add :closed_at, :utc_datetime_usec
      add :closed_reason, :string
      add :archived, :boolean, default: false
      add :archived_at, :utc_datetime_usec

      # Match day
      add :is_match_thread, :boolean, default: false
      add :match_mode, :string
      add :match_id, :string

      # Chain
      add :continuation_topic_id, :integer
      add :parent_topic_id, :integer

      # Relationships
      add :user_id, references(:users, on_delete: :nilify_all)
      add :category_id, references(:categories, on_delete: :nilify_all)
      add :first_post_id, :integer
      add :last_post_id, :integer

      timestamps(type: :utc_datetime_usec)
      add :bumped_at, :utc_datetime_usec
    end

    create unique_index(:topics, [:slug])
    create index(:topics, [:category_id])
    create index(:topics, [:bumped_at])
    create index(:topics, [:is_match_thread])
    create index(:topics, [:match_id])
    create index(:topics, [:user_id])
    create index(:topics, [:pinned, :bumped_at])
    create index(:topics, [:archived, :closed])
  end
end
