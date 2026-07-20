defmodule Colloq.Repo.Migrations.TrustThresholdsAndTagCaps do
  use Ecto.Migration

  @moduledoc """
  Raises the promotion thresholds and moves the per-topic tag cap onto the
  trust level.

  Until now `TrustPromotionWorker` hardcoded its own thresholds and ignored
  `trust_levels.min_posts` entirely, so the column was decorative. The worker
  now reads these rows, which makes them the single source of truth — hence
  updating existing rows here rather than only in seeds (seeds run on a fresh
  DB, which prod is not).

  `max_tags_per_topic` uses **-1 for unlimited**, NOT the 0-means-unlimited
  convention of the sibling `daily_*_limit` columns: TL0 must be able to
  express "no tagging at all", which 0 has to mean here.
  """

  def up do
    alter table(:trust_levels) do
      add :max_tags_per_topic, :integer, default: 5, null: false
    end

    # level => {min_posts, min_days_registered, max_tags_per_topic}
    # TL3/TL4 carry no day requirement — they gate on post count alone.
    levels = %{
      0 => {0, 0, 0},
      1 => {1_000, 1, 5},
      2 => {2_500, 7, 10},
      3 => {6_500, 0, 15},
      4 => {10_000, 0, -1}
    }

    for {level, {min_posts, min_days, max_tags}} <- levels do
      execute("""
      UPDATE trust_levels
         SET min_posts = #{min_posts},
             min_days_registered = #{min_days},
             max_tags_per_topic = #{max_tags}
       WHERE level = #{level}
      """)
    end
  end

  def down do
    # Restore the values seeded by 000012 / the original seeds.exs.
    levels = %{
      0 => {0, 0},
      1 => {10, 1},
      2 => {50, 7},
      3 => {200, 30},
      4 => {0, 0}
    }

    for {level, {min_posts, min_days}} <- levels do
      execute("""
      UPDATE trust_levels
         SET min_posts = #{min_posts},
             min_days_registered = #{min_days}
       WHERE level = #{level}
      """)
    end

    alter table(:trust_levels) do
      remove :max_tags_per_topic
    end
  end
end
