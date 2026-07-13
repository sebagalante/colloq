defmodule Colloq.Repo.Migrations.DropTopicSlugUnique do
  use Ecto.Migration

  # Topic URLs are /t/:id/:slug, so the id disambiguates — the slug does not need
  # to be globally unique. A unique index made duplicate-title topics fail to
  # insert (crashing topic creation). Replace it with a plain index.
  def up do
    drop_if_exists index(:topics, [:slug])
    create_if_not_exists index(:topics, [:slug])
  end

  def down do
    drop_if_exists index(:topics, [:slug])
    create_if_not_exists unique_index(:topics, [:slug])
  end
end
