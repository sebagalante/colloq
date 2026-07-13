defmodule Colloq.Repo.Migrations.TopicArchiving do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add_if_not_exists :closed, :boolean, default: false
      add_if_not_exists :closed_at, :utc_datetime_usec
      add_if_not_exists :closed_reason, :string
      add_if_not_exists :archived, :boolean, default: false
      add_if_not_exists :archived_at, :utc_datetime_usec
      add_if_not_exists :continuation_topic_id, :integer
      add_if_not_exists :parent_topic_id, :integer
    end

    create_if_not_exists index(:topics, [:continuation_topic_id])
    create_if_not_exists index(:topics, [:parent_topic_id])
  end
end
