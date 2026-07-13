defmodule Colloq.Repo.Migrations.AddTotpToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists :totp_secret, :binary
      add_if_not_exists :totp_enabled, :boolean, default: false
      add_if_not_exists :totp_backup_codes, {:array, :string}, default: []
      add_if_not_exists :totp_last_used_at, :utc_datetime_usec
      add_if_not_exists :totp_pending_secret, :binary
    end
  end
end
