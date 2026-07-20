defmodule Colloq.Repo.Migrations.CreateTopicReads do
  use Ecto.Migration

  def change do
    create table(:topic_reads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :topic_id, references(:topics, on_delete: :delete_all), null: false
      # Highest post_number the user has seen in this topic. On the next visit
      # we scroll to the first post above this number ("where you left off").
      add :last_read_post_number, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:topic_reads, [:user_id, :topic_id])
    create index(:topic_reads, [:topic_id])
  end
end
