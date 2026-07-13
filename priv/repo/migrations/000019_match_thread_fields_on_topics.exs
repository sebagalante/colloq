defmodule Colloq.Repo.Migrations.MatchThreadFieldsOnTopics do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add_if_not_exists :is_match_thread, :boolean, default: false
      add_if_not_exists :match_mode, :string
      add_if_not_exists :match_id, :string
    end

    create_if_not_exists index(:topics, [:is_match_thread])
    create_if_not_exists index(:topics, [:match_id])
  end
end
