defmodule Colloq.Repo.Migrations.AddParentIdToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add_if_not_exists :parent_id, references(:posts, on_delete: :nilify_all)
    end

    create_if_not_exists index(:posts, [:parent_id])
  end
end
