defmodule Colloq.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add_if_not_exists :role, :string
    end

    execute "UPDATE users SET role = 'super_admin' WHERE is_admin = true"

    create_if_not_exists index(:users, [:role])
  end

  def down do
    drop index(:users, [:role])

    alter table(:users) do
      remove :role
    end
  end
end
