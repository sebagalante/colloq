defmodule Colloq.Repo.Migrations.CreateReactions do
  use Ecto.Migration

  def change do
    create table(:reactions) do
      add :post_id, references(:posts, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :emoji, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:reactions, [:post_id, :user_id, :emoji])
  end
end
