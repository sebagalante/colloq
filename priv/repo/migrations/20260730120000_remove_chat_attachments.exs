defmodule Colloq.Repo.Migrations.RemoveChatAttachments do
  use Ecto.Migration

  @moduledoc """
  Drops DM file attachments.

  Attachment storage was unbounded: nothing ever called `Colloq.Media.R2.delete/2`,
  so every uploaded file stayed in the bucket forever, including files whose
  message had been soft-deleted. Removing the feature removes the leak.

  Stickers were riding on the same three columns (`attachment_type == "sticker"`),
  so they move to a dedicated `sticker_url` first.
  """

  def up do
    alter table(:messages) do
      add :sticker_url, :string
    end

    execute """
    UPDATE messages
       SET sticker_url = attachment_url
     WHERE attachment_type = 'sticker'
       AND attachment_url IS NOT NULL
    """

    # Attachment-only messages have no body to fall back on, so once the columns
    # are gone they would render as permanently empty bubbles.
    execute """
    DELETE FROM messages
     WHERE attachment_url IS NOT NULL
       AND attachment_type IS DISTINCT FROM 'sticker'
       AND (body IS NULL OR body = '')
    """

    # `conversations.last_message_id` has no FK behind it, so a delete above can
    # leave it pointing at a row that no longer exists. Repoint each affected
    # conversation at its newest surviving message.
    execute """
    UPDATE conversations c
       SET last_message_id = (
             SELECT m.id FROM messages m
              WHERE m.conversation_id = c.id
              ORDER BY m.inserted_at DESC
              LIMIT 1
           )
     WHERE c.last_message_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.id = c.last_message_id)
    """

    alter table(:messages) do
      remove :attachment_url
      remove :attachment_name
      remove :attachment_type
    end
  end

  def down do
    alter table(:messages) do
      add :attachment_url, :string
      add :attachment_name, :string
      add :attachment_type, :string
    end

    execute """
    UPDATE messages
       SET attachment_url = sticker_url,
           attachment_name = 'sticker',
           attachment_type = 'sticker'
     WHERE sticker_url IS NOT NULL
    """

    alter table(:messages) do
      remove :sticker_url
    end
  end
end
