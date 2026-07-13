defmodule Colloq.Repo.Migrations.AddParentToCategories do
  use Ecto.Migration

  def change do
    alter table(:categories) do
      add :parent_id, references(:categories, on_delete: :nilify_all)
    end

    create index(:categories, [:parent_id])
  end
end
