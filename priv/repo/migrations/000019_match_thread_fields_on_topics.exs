defmodule Colloq.Repo.Migrations.MatchThreadFieldsOnTopics do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add :is_match_thread, :boolean, default: false
      add :match_mode, :string
      add :match_id, :string
    end

    create index(:topics, [:is_match_thread])
    create index(:topics, [:match_id])
  end
end
