defmodule Colloq.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :body, :text, null: false
      add :body_json, :map
      add :post_number, :integer, null: false
      add :deleted_at, :utc_datetime_usec

      # Counters
      add :view_count, :integer, default: 0
      add :reactions_count, :integer, default: 0

      # System/bot posts
      add :is_system, :boolean, default: false
      add :system_type, :string
      add :event_data, :map

      # Relationships
      add :topic_id, references(:topics, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:posts, [:topic_id])
    create index(:posts, [:user_id])
    create index(:posts, [:inserted_at])
    create index(:posts, [:is_system, :topic_id])
    create unique_index(:posts, [:topic_id, :post_number])

    # Add post count trigger on topics
    execute("""
    CREATE OR REPLACE FUNCTION update_topic_post_count()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'INSERT' AND NEW.deleted_at IS NULL THEN
        UPDATE topics SET posts_count = posts_count + 1 WHERE id = NEW.topic_id;
      ELSIF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        UPDATE topics SET posts_count = posts_count - 1 WHERE id = NEW.topic_id;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER post_count_trigger
    AFTER INSERT OR UPDATE ON posts
    FOR EACH ROW EXECUTE FUNCTION update_topic_post_count();
    """)
  end
end
