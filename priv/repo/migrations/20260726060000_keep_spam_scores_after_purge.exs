defmodule Colloq.Repo.Migrations.KeepSpamScoresAfterPurge do
  @moduledoc """
  Lets a classification outlive the post it scored.

  `spam_classifications.post_id` cascaded, so hard-deleting old spam would have
  silently erased the matching rows from the classifier dashboard — the score
  distribution would lose its history exactly as it becomes useful for choosing
  a threshold. The dashboard only needs score, threshold, mode and date; the
  post is a convenience link.

  Paired with `Colloq.Workers.PrunePostsWorker`, which is what starts deleting
  posts for real.
  """
  use Ecto.Migration

  def up do
    drop constraint(:spam_classifications, "spam_classifications_post_id_fkey")

    alter table(:spam_classifications) do
      modify :post_id, references(:posts, on_delete: :nilify_all), null: true
    end
  end

  def down do
    # Rows whose post is already gone can't satisfy the NOT NULL, so drop them
    # rather than failing the rollback.
    execute "DELETE FROM spam_classifications WHERE post_id IS NULL"

    drop constraint(:spam_classifications, "spam_classifications_post_id_fkey")

    alter table(:spam_classifications) do
      modify :post_id, references(:posts, on_delete: :delete_all), null: false
    end
  end
end
