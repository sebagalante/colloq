defmodule Colloq.Repo.Migrations.ParadedbSearchSetup do
  use Ecto.Migration

  def up do
    if pg_search_available?() do
      execute("CREATE EXTENSION IF NOT EXISTS pg_search")

      execute("DROP INDEX IF EXISTS posts_body_gin_idx")

      execute("""
      CALL paradedb.create_bm25(
        table_name => 'posts',
        index_name => 'posts_body_idx',
        key_field => 'id',
        text_fields => paradedb.field('body')
      )
      """)

      execute("""
      CALL paradedb.create_bm25(
        table_name => 'topics',
        index_name => 'topics_title_idx',
        key_field => 'id',
        text_fields => paradedb.field('title')
      )
      """)
    else
      # pg_search is not installed on this server (e.g. local dev on stock
      # Postgres). Skip BM25 index setup — Colloq.Forum's search functions
      # fall back to [] until the extension is present. Re-run this migration
      # after installing pg_search to build the indexes.
    end
  end

  def down do
    execute("DROP INDEX IF EXISTS posts_body_idx")
    execute("DROP INDEX IF EXISTS topics_title_idx")
  end

  defp pg_search_available? do
    %{num_rows: rows} =
      repo().query!("SELECT 1 FROM pg_available_extensions WHERE name = 'pg_search'")

    rows > 0
  end
end
