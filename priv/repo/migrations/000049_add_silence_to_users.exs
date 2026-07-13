defmodule Colloq.Repo.Migrations.AddSilenceToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :silenced_until, :utc_datetime_usec
      add :silenced_at, :utc_datetime_usec
      add :silence_reason, :string
    end
  end
end
