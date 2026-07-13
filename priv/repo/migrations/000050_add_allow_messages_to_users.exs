defmodule Colloq.Repo.Migrations.AddAllowMessagesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :allow_messages, :boolean, default: true, null: false
    end
  end
end
