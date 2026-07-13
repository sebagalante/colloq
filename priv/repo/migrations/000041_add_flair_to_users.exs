defmodule Colloq.Repo.Migrations.AddFlairToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists :flair, :string
    end
  end
end
