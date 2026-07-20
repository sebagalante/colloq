defmodule Colloq.Repo.Migrations.AddStaffOnlyToTopics do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      # Announcement mode: staff can post, regular users read only.
      add :staff_only, :boolean, default: false, null: false
    end
  end
end
