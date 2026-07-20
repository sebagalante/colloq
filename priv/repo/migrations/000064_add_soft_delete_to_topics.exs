defmodule Colloq.Repo.Migrations.AddSoftDeleteToTopics do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add :deleted_at, :utc_datetime_usec
      add :deleted_by_id, references(:users, on_delete: :nilify_all)
    end

    # Deleted topics are excluded from every listing, so an index on the flag
    # keeps those "WHERE deleted_at IS NULL" scans cheap.
    create index(:topics, [:deleted_at])
  end
end
