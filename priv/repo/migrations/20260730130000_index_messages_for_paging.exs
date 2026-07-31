defmodule Colloq.Repo.Migrations.IndexMessagesForPaging do
  use Ecto.Migration

  @moduledoc """
  Supports the keyset pagination in `Colloq.Messaging.list_messages/3`, which
  filters on `conversation_id` and walks `(inserted_at, id)` backwards.

  The old single-column `conversation_id` index left the planner sorting the
  whole conversation on every page. This one is a prefix superset of it, so the
  cascade delete from `conversations` is still covered and the old index is
  redundant.
  """

  def up do
    create index(:messages, [:conversation_id, :inserted_at, :id])
    drop_if_exists index(:messages, [:conversation_id])
  end

  def down do
    create index(:messages, [:conversation_id])
    drop_if_exists index(:messages, [:conversation_id, :inserted_at, :id])
  end
end
