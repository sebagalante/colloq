defmodule Colloq.Repo.Migrations.TopicArchiving do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add :closed, :boolean, default: false
      add :closed_at, :utc_datetime_usec
      add :closed_reason, :string
      add :archived, :boolean, default: false
      add :archived_at, :utc_datetime_usec
      add :continuation_topic_id, :integer
      add :parent_topic_id, :integer
    end

    create index(:topics, [:continuation_topic_id])
    create index(:topics, [:parent_topic_id])
  end
end
