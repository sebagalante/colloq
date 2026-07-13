defmodule Colloq.Repo.Migrations.AddViewCountToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add_if_not_exists :view_count, :integer, default: 0
    end
  end
end
