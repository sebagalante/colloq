defmodule Colloq.Repo.Migrations.CreateFlags do
  use Ecto.Migration

  def change do
    create table(:flags) do
      add :reason, :string, null: false
      add :resolved, :boolean, default: false
      add :resolved_at, :utc_datetime_usec
      add :resolution, :string

      add :post_id, references(:posts, on_delete: :delete_all)
      add :topic_id, references(:topics, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :resolved_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:flags, [:post_id])
    create index(:flags, [:resolved])
    create index(:flags, [:user_id])
    create index(:flags, [:inserted_at])
  end
end
