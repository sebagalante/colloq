defmodule Colloq.Repo.Migrations.AddDuplicateOfToTopics do
  use Ecto.Migration

  @moduledoc """
  Records which topic a duplicate was closed in favour of.

  Auto-closing a re-post left the reader with "This topic is closed: duplicate"
  and no way to reach the actual conversation — a dead end for anyone arriving
  from search. Discourse's practice is that a duplicate always points at the
  original; this is the pointer.

  `nilify_all`: if the original is ever deleted the duplicate stays closed but
  simply stops claiming to duplicate something that no longer exists.
  """

  def change do
    alter table(:topics) do
      add :duplicate_of_id, references(:topics, on_delete: :nilify_all)
    end

    create index(:topics, [:duplicate_of_id], where: "duplicate_of_id IS NOT NULL")
  end
end
