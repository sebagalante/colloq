defmodule Colloq.Repo.Migrations.CapTagsPerTopicAtThree do
  @moduledoc """
  Tightens the per-topic tag cap to 3 for TL1–TL3.

  The caps seeded by `000067_trust_thresholds_and_tag_caps` (5/10/15) were far
  above real use: at the time of this change no topic in the forum carried more
  than 2 tags, so 15 only ever bought noise. TL4 keeps `-1` (unlimited) for
  curation work, and TL0 keeps `0` (no tagging at all).
  """
  use Ecto.Migration

  # {level, new_cap, previous_cap} — previous values restored on rollback.
  @caps [{1, 3, 5}, {2, 3, 10}, {3, 3, 15}]

  def up do
    for {level, cap, _old} <- @caps do
      execute "UPDATE trust_levels SET max_tags_per_topic = #{cap} WHERE level = #{level}"
    end
  end

  def down do
    for {level, _cap, old} <- @caps do
      execute "UPDATE trust_levels SET max_tags_per_topic = #{old} WHERE level = #{level}"
    end
  end
end
