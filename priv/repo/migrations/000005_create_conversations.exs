defmodule Colloq.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :user1_id, references(:users, on_delete: :delete_all)
      add :user2_id, references(:users, on_delete: :delete_all)
      add :last_message_id, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversations, [:user1_id, :user2_id])
    create index(:conversations, [:user1_id])
    create index(:conversations, [:user2_id])
    create index(:conversations, [:updated_at])
  end
end
