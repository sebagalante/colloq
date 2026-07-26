defmodule Colloq.Repo.Migrations.CreateInvites do
  @moduledoc """
  Invitations for `registration_mode = "invite"`.

  One row per invited address. The token is the secret in the signup link, so it
  is unique and indexed; `email` is *not* unique — an address that was invited,
  never accepted, and is invited again gets a fresh row rather than silently
  reusing a token that may already be in someone's inbox.
  """
  use Ecto.Migration

  def change do
    create table(:invites) do
      add :email, :string, null: false
      add :token, :string, null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :accepted_by_id, references(:users, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :sent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invites, [:token])
    create index(:invites, [:email])
    create index(:invites, [:invited_by_id])

    # The pending-invite lookup at signup: one open invite per address at a time.
    create index(:invites, [:email, :accepted_at])
  end
end
