defmodule Colloq.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks) do
      add :url, :string, null: false
      add :secret, :string
      add :events, {:array, :string}, default: []
      add :active, :boolean, default: true
      add :last_delivery_at, :utc_datetime_usec
      add :last_status, :string

      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhooks, [:user_id])
    create index(:webhooks, [:active])
  end
end
