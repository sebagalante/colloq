defmodule Colloq.Repo.Migrations.FixEmbedsUniqueIndex do
  use Ecto.Migration

  # The original unique index on `url` alone made a URL previewable on only ONE
  # post ever — any second post using the same link (a quote, a repost) failed
  # to create an embed. Uniqueness should be per (post_id, url).
  def change do
    drop_if_exists unique_index(:embeds, [:url])
    create_if_not_exists unique_index(:embeds, [:post_id, :url])
  end
end
