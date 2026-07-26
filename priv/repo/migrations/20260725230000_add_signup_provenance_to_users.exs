defmodule Colloq.Repo.Migrations.AddSignupProvenanceToUsers do
  @moduledoc """
  Records the address an account was created from.

  `last_ip` only ever held the *most recent login*, written by
  `Accounts.record_login/2` — so by the time an account looked suspicious, the
  address it registered from had already been overwritten.

  Only the IP is stored. Country and network are resolved at render time from
  GeoLite2, matching the decision already documented on the admin user list:
  the answer changes as MaxMind updates, and keeping members' locations in our
  own tables is a commitment not worth making for an admin hint.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :signup_ip, :string
    end

    # Supports "which other accounts registered from this address".
    create index(:users, [:signup_ip])
  end
end
