defmodule Colloq.Repo.Migrations.CreateBadges do
  use Ecto.Migration

  def change do
    create table(:badges) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :icon, :string, default: "🏅"
      add :color, :string, default: "#3b82f6"
      add :position, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:badges, [:slug])

    create table(:user_badges) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :badge_id, references(:badges, on_delete: :delete_all), null: false
      add :granted_by_id, references(:users, on_delete: :nilify_all)
      add :display_position, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_badges, [:user_id])
    create index(:user_badges, [:badge_id])
    create unique_index(:user_badges, [:user_id, :badge_id])
  end
end
