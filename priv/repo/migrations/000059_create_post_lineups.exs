defmodule Colloq.Repo.Migrations.CreatePostLineups do
  use Ecto.Migration

  def change do
    create table(:post_lineups) do
      add :post_id, references(:posts, on_delete: :delete_all), null: false
      add :team_id, :integer, null: false
      add :formation, :string, null: false
      # Frozen snapshot of the chosen XI: [%{"slot" => 0, "name" => "...",
      # "player_id" => "...", "role" => "gk"}, ...]. Kept as data (not an
      # image) so lineups stay queryable/aggregatable.
      add :players, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:post_lineups, [:post_id])
  end
end
