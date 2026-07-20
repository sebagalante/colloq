defmodule Colloq.Repo.Migrations.BackfillPostCounts do
  use Ecto.Migration

  @moduledoc """
  Recomputes `topics.posts_count` and `users.posts_count` from the posts table.

  Both had drifted, for two reasons now fixed in `Colloq.Forum`:

    * `create_post/3` set `topics.posts_count = post_number`, a high-water mark
      that only ever climbs. Once any post in a topic was deleted the count
      permanently overstated — one topic showed "1 / 8" with a single visible
      post.
    * `delete_post/2` soft-deleted without touching either counter, so both kept
      counting posts nobody can see.

  Counts reflect *visible* posts: soft-deleted rows are excluded, matching what
  the timeline scrubber and profile stats claim to show.
  """

  def up do
    execute("""
    UPDATE topics t
       SET posts_count = COALESCE((
             SELECT count(*) FROM posts p
              WHERE p.topic_id = t.id AND p.deleted_at IS NULL
           ), 0)
    """)

    execute("""
    UPDATE users u
       SET posts_count = COALESCE((
             SELECT count(*) FROM posts p
              WHERE p.user_id = u.id AND p.deleted_at IS NULL
           ), 0)
    """)
  end

  def down do
    # The previous values were wrong by definition; there is nothing to restore.
    :ok
  end
end
