defmodule Colloq.Repo.Migrations.CreateVoiceRooms do
  use Ecto.Migration

  def change do
    create table(:voice_rooms) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :topic_id, references(:topics, on_delete: :nilify_all)
      add :trust_level_required, :integer, default: 0
      add :max_participants, :integer, default: 10
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :ephemeral, :boolean, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:voice_rooms, [:slug])
    create index(:voice_rooms, [:topic_id])
  end
end
