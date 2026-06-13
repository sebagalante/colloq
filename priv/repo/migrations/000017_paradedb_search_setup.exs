defmodule Colloq.Repo.Migrations.ParadedbSearchSetup do
  use Ecto.Migration

  def change do
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
  end
end
