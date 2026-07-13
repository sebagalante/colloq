defmodule Colloq.Repo.Migrations.CreatePolls do
  use Ecto.Migration

  def change do
    create table(:polls) do
      add :question, :string, null: false
      add :closed, :boolean, default: false
      add :closed_at, :utc_datetime_usec
      add :multiple, :boolean, default: false
      add :post_id, references(:posts, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:polls, [:post_id])

    create table(:poll_options) do
      add :text, :string, null: false
      add :position, :integer, default: 0
      add :poll_id, references(:polls, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:poll_options, [:poll_id])

    create table(:poll_votes) do
      add :poll_option_id, references(:poll_options, on_delete: :delete_all), null: false
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:poll_votes, [:poll_id])
    create index(:poll_votes, [:user_id])
    create unique_index(:poll_votes, [:poll_id, :user_id, :poll_option_id])
  end
end
