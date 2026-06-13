defmodule Colloq.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :username, :string, null: false
      add :display_name, :string
      add :password_hash, :string

      # Trust system
      add :trust_level, :integer, default: 0, null: false
      add :posts_count, :integer, default: 0, null: false
      add :is_admin, :boolean, default: false, null: false

      # OAuth
      add :oauth_provider, :string
      add :oauth_uid, :string
      add :avatar_url, :string

      # Profile
      add :bio, :text
      add :location, :string
      add :website, :string

      # Preferences
      add :theme, :string, default: "dark"
      add :locale, :string, default: "es"
      add :notifications_enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:username])
    create unique_index(:users, [:oauth_provider, :oauth_uid], where: "oauth_provider IS NOT NULL")
    create index(:users, [:trust_level])
  end
end
