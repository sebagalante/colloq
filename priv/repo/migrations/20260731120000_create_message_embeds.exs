defmodule Colloq.Repo.Migrations.CreateMessageEmbeds do
  use Ecto.Migration

  # Link previews for chat messages. Separate from `embeds` (which is post-scoped
  # and unique on :url globally) — the same link sent in two chats needs two
  # cards, and a DM preview must never be reachable from a post.
  def change do
    create table(:message_embeds) do
      add :url, :string, null: false
      add :host, :string, null: false
      add :title, :string
      add :description, :text
      add :image_url, :string

      add :message_id, references(:messages, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:message_embeds, [:message_id])
    create unique_index(:message_embeds, [:message_id, :url])
  end
end
