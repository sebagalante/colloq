defmodule Colloq.Repo.Migrations.CreateTrustLevels do
  use Ecto.Migration

  def change do
    create table(:trust_levels) do
      add :level, :integer, null: false
      add :name, :string, null: false
      add :min_posts, :integer, default: 0
      add :min_days_registered, :integer, default: 0
      add :can_create_topics, :boolean, default: true
      add :can_send_pms, :boolean, default: true
      add :can_edit_posts, :boolean, default: true
      add :can_flag_posts, :boolean, default: true
      add :can_upload_images, :boolean, default: true
      add :daily_post_limit, :integer, default: 0  # 0 = unlimited
      add :daily_reaction_limit, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trust_levels, [:level])
    create unique_index(:trust_levels, [:name])
  end
end
