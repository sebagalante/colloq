defmodule Colloq.Repo.Migrations.AddArchivedAtToNotifications do
  use Ecto.Migration

  @moduledoc """
  Lets users archive a notification instead of only deleting it.

  Until now the inbox offered "Clear read" / "Clear all", both irreversible
  `DELETE`s. Archiving keeps the row but hides it from the inbox and from the
  unread badge.

  `archived_at` doubles as the flag and the timestamp — NULL means "in the
  inbox". The partial index covers the default listing, which always filters on
  `archived_at IS NULL`.
  """

  def change do
    alter table(:notifications) do
      add :archived_at, :utc_datetime_usec
    end

    create index(:notifications, [:user_id, :inserted_at],
             where: "archived_at IS NULL",
             name: :notifications_inbox_index
           )

    create index(:notifications, [:user_id, :archived_at],
             where: "archived_at IS NOT NULL",
             name: :notifications_archived_index
           )
  end
end
