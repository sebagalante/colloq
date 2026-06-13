defmodule Colloq.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages) do
      add :topic_id, references(:topics, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :body, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:chat_messages, [:inserted_at])
    create index(:chat_messages, [:topic_id])
    create index(:chat_messages, [:user_id])
  end
end
