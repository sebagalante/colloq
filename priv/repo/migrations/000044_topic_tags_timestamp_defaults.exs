defmodule Colloq.Repo.Migrations.TopicTagsTimestampDefaults do
  use Ecto.Migration

  @moduledoc """
  The `topic_tags` join table is inserted into via a string `join_through`
  many_to_many, which does not populate `inserted_at`/`updated_at`. Those
  columns are NOT NULL, so tagging a topic raised a not-null violation and
  rolled back the whole topic creation. Give them a DB-side default so the
  join insert succeeds.
  """
  def up do
    alter table(:topic_tags) do
      modify :inserted_at, :utc_datetime_usec, default: fragment("now()"), null: false
      modify :updated_at, :utc_datetime_usec, default: fragment("now()"), null: false
    end
  end

  def down do
    alter table(:topic_tags) do
      modify :inserted_at, :utc_datetime_usec, default: nil, null: false
      modify :updated_at, :utc_datetime_usec, default: nil, null: false
    end
  end
end
