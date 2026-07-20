defmodule Colloq.Repo.Migrations.AddLastWarningReasonToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_warning_reason, :string
    end
  end
end
