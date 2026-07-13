defmodule Colloq.Repo.Migrations.AddDeletionToMessaging do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :deleted_at, :utc_datetime_usec
    end

    # Per-user "delete for me": each participant can hide a conversation without
    # removing it for the other. A new message bumps `updated_at` past the
    # deletion mark, so the thread reappears.
    alter table(:conversations) do
      add :user1_deleted_at, :utc_datetime_usec
      add :user2_deleted_at, :utc_datetime_usec
    end
  end
end
