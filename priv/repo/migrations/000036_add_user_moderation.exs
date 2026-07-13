defmodule Colloq.Repo.Migrations.AddUserModeration do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Suspension (temporary)
      add_if_not_exists :suspended_until, :utc_datetime_usec
      add_if_not_exists :suspended_at, :utc_datetime_usec
      add_if_not_exists :suspension_reason, :text

      # Ban (permanent)
      add_if_not_exists :banned, :boolean, default: false
      add_if_not_exists :banned_at, :utc_datetime_usec
      add_if_not_exists :ban_reason, :text

      # Warnings
      add_if_not_exists :warnings_count, :integer, default: 0
      add_if_not_exists :last_warning_at, :utc_datetime_usec
    end

    create_if_not_exists index(:users, [:banned])
    create_if_not_exists index(:users, [:suspended_until])
  end
end
