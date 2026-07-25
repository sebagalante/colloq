defmodule Colloq.Repo.Migrations.UniquePostDraftsPerUserTopic do
  use Ecto.Migration

  @moduledoc """
  One draft per user per topic, enforced by the database.

  `Forum.save_draft/3` reads-then-writes, so two concurrent saves (two tabs)
  could leave duplicate rows. Two *partial* indexes rather than one plain
  index: Postgres treats NULLs as distinct, so a single unique index on
  (user_id, topic_id) would not constrain the new-topic draft, which is
  exactly the row where topic_id is NULL.
  """

  def up do
    # Collapse any duplicates already stored, keeping the most recently touched
    # row — the same one get_draft/2 has been returning.
    execute("""
    DELETE FROM post_drafts d
     USING post_drafts newer
     WHERE d.user_id = newer.user_id
       AND d.topic_id IS NOT DISTINCT FROM newer.topic_id
       AND (d.updated_at, d.id) < (newer.updated_at, newer.id)
    """)

    create unique_index(:post_drafts, [:user_id, :topic_id],
             where: "topic_id IS NOT NULL",
             name: :post_drafts_user_topic_index
           )

    create unique_index(:post_drafts, [:user_id],
             where: "topic_id IS NULL",
             name: :post_drafts_user_new_topic_index
           )
  end

  def down do
    drop index(:post_drafts, [:user_id, :topic_id], name: :post_drafts_user_topic_index)
    drop index(:post_drafts, [:user_id], name: :post_drafts_user_new_topic_index)
  end
end
