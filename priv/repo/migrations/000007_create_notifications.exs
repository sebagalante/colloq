defmodule Colloq.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :type, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :data, :map, default: %{}

      add :read, :boolean, default: false
      add :read_at, :utc_datetime_usec
      add :email_sent, :boolean, default: false
      add :email_sent_at, :utc_datetime_usec

      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notifications, [:user_id])
    create index(:notifications, [:read, :user_id])
    create index(:notifications, [:inserted_at])
    create index(:notifications, [:type, :user_id])
  end
end
