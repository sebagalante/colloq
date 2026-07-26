defmodule Colloq.Repo.Migrations.CreateSpamClassifications do
  @moduledoc """
  One row per ML spam screening.

  Shadow mode's whole purpose is "watch the scores for a week, then pick a
  threshold" — but the scores only ever went to the log, so answering "what
  would 0.85 have caught?" meant grepping journald and doing arithmetic by hand.
  Stored, the same question is a query.

  Only the score and the decision are kept, never the post text: the body is one
  join away in `posts`, and copying it here would mean a deleted post lives on
  in a second table.
  """
  use Ecto.Migration

  def change do
    create table(:spam_classifications) do
      add :post_id, references(:posts, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)

      add :score, :float, null: false
      add :threshold, :float, null: false
      # What the score implied, independent of whether anything was done about it.
      add :would_flag, :boolean, null: false, default: false
      # "shadow" | "enforce" — the mode in force when this was screened, so a
      # later mode change doesn't rewrite the history of what actually happened.
      add :mode, :string, null: false
      add :acted, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:spam_classifications, [:inserted_at])
    create index(:spam_classifications, [:post_id])
    create index(:spam_classifications, [:would_flag])
  end
end
