defmodule Colloq.Repo.Migrations.AddReplyToMessages do
  use Ecto.Migration

  @moduledoc """
  Inline replies: a message may quote an earlier one in the same conversation.

  `nilify_all` rather than a cascade — deleting the quoted message must not take
  the replies with it. The reply survives and renders its quote as "message
  deleted", which is also what the soft-delete path produces.
  """

  def change do
    alter table(:messages) do
      add :reply_to_id, references(:messages, on_delete: :nilify_all)
    end

    create index(:messages, [:reply_to_id])
  end
end
