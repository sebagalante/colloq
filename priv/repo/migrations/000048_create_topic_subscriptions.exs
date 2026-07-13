defmodule Colloq.Repo.Migrations.CreateTopicSubscriptions do
  use Ecto.Migration

  def change do
    create table(:topic_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :topic_id, references(:topics, on_delete: :delete_all), null: false
      # "watching" | "tracking" | "normal" | "muted"
      add :level, :string, null: false, default: "normal"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:topic_subscriptions, [:user_id, :topic_id])
    create index(:topic_subscriptions, [:topic_id, :level])
  end
end
