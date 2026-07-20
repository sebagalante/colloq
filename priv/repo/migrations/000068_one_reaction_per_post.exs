defmodule Colloq.Repo.Migrations.OneReactionPerPost do
  use Ecto.Migration

  @moduledoc """
  One reaction per user per post, and no reacting to your own post.

  Reactions were unique on `(post_id, user_id, emoji)`, which let one user pile
  several different emojis onto the same post. The rule is now one reaction per
  post — switching emoji replaces the previous choice — so the index moves to
  `(post_id, user_id)`.

  Existing data violates both new rules, and a unique index cannot be created
  while duplicates exist, so this cleans up first. **Both deletions are
  irreversible** — `down/0` restores the looser index but cannot bring rows back.
  """

  def up do
    # Self-reactions: the app never notified on these (notify_reaction/3 already
    # guarded against it), so they only ever inflated counts.
    execute("""
    DELETE FROM reactions r
     USING posts p
     WHERE p.id = r.post_id
       AND p.user_id = r.user_id
    """)

    # Multi-emoji reactions: keep each user's most recent reaction per post.
    # ctid breaks ties when two rows share an inserted_at.
    execute("""
    DELETE FROM reactions
     WHERE ctid NOT IN (
       SELECT DISTINCT ON (post_id, user_id) ctid
         FROM reactions
        ORDER BY post_id, user_id, inserted_at DESC, ctid DESC
     )
    """)

    drop unique_index(:reactions, [:post_id, :user_id, :emoji])
    create unique_index(:reactions, [:post_id, :user_id])

    # Counters drifted as rows were removed above.
    execute("""
    UPDATE posts p
       SET reactions_count = COALESCE(
         (SELECT COUNT(*) FROM reactions r WHERE r.post_id = p.id), 0)
    """)
  end

  def down do
    drop unique_index(:reactions, [:post_id, :user_id])
    create unique_index(:reactions, [:post_id, :user_id, :emoji])
  end
end
