defmodule Colloq.Repo.Migrations.AddBodyJsonToPosts do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      add :body_json, :map
    end

    execute("CREATE INDEX IF NOT EXISTS posts_body_json_gin_idx ON posts USING GIN (body_json)")
  end
end
