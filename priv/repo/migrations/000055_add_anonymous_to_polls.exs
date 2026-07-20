defmodule Colloq.Repo.Migrations.AddAnonymousToPolls do
  use Ecto.Migration

  def change do
    alter table(:polls) do
      # Secret ballot: hide who voted for what when true.
      add :anonymous, :boolean, default: false, null: false
    end
  end
end
