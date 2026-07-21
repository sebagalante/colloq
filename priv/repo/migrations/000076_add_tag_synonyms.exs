defmodule Colloq.Repo.Migrations.AddTagSynonyms do
  use Ecto.Migration

  @moduledoc """
  Tag synonyms: a tag can point at another tag as its canonical form.

  Users create tags freely, so the same subject drifts into several spellings —
  `f1` and `formula1`, `libertadores` and `copa-libertadores-2026`. Each split
  halves the usefulness of both, and there is currently no way to merge them
  after the fact. A synonym redirects at tagging time, so applying `f1` stores
  `formula1` instead and the two stop competing.

  `nilify_all` on delete: removing a canonical tag must leave its synonyms as
  ordinary tags rather than cascading them into oblivion.
  """

  def change do
    alter table(:tags) do
      add :synonym_of_id, references(:tags, on_delete: :nilify_all)
    end

    create index(:tags, [:synonym_of_id])
  end
end
