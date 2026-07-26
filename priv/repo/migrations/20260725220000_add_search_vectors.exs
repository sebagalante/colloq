defmodule Colloq.Repo.Migrations.AddSearchVectors do
  @moduledoc """
  Full-text search for topics and posts.

  Replaces the `ILIKE '%term%'` scans, which couldn't use an index, had no
  ranking (results came back by date regardless of relevance), and matched no
  word forms — "goles" never found "gol".

  Two pieces:

    * `es_unaccent` — the stock `spanish` config with `unaccent` in front of the
      stemmer, so "analisis" matches "análisis". A configuration is used rather
      than calling `unaccent()` directly because that function is STABLE, not
      IMMUTABLE, and so can't appear in a generated column or an index — while
      `to_tsvector('literal_config', text)` is immutable.

    * `search_vector` generated columns on `topics` and `posts`, kept in sync by
      Postgres itself (no triggers, no application writes), each backed by GIN.

  Post bodies are Tiptap HTML, so the tags are stripped in the expression —
  otherwise every post would match "p", "br" and "div".
  """
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS unaccent"

    execute """
    CREATE TEXT SEARCH CONFIGURATION es_unaccent (COPY = spanish)
    """

    execute """
    ALTER TEXT SEARCH CONFIGURATION es_unaccent
      ALTER MAPPING FOR hword, hword_part, word
      WITH unaccent, spanish_stem
    """

    execute """
    ALTER TABLE topics
      ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (to_tsvector('es_unaccent', coalesce(title, ''))) STORED
    """

    execute """
    ALTER TABLE posts
      ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        to_tsvector('es_unaccent', regexp_replace(coalesce(body, ''), '<[^>]*>', ' ', 'g'))
      ) STORED
    """

    create index(:topics, [:search_vector], using: :gin)
    create index(:posts, [:search_vector], using: :gin)
  end

  def down do
    drop_if_exists index(:posts, [:search_vector], using: :gin)
    drop_if_exists index(:topics, [:search_vector], using: :gin)

    execute "ALTER TABLE posts DROP COLUMN IF EXISTS search_vector"
    execute "ALTER TABLE topics DROP COLUMN IF EXISTS search_vector"
    execute "DROP TEXT SEARCH CONFIGURATION IF EXISTS es_unaccent"
    # `unaccent` is left installed: dropping an extension other things may have
    # started using is not this migration's call.
  end
end
