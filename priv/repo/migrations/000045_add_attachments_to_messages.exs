defmodule Colloq.Repo.Migrations.AddAttachmentsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :attachment_url, :string
      add :attachment_name, :string
      add :attachment_type, :string
    end

    # Body is no longer required once a message can be a pure attachment.
    execute "ALTER TABLE messages ALTER COLUMN body DROP NOT NULL",
            "ALTER TABLE messages ALTER COLUMN body SET NOT NULL"
  end
end
