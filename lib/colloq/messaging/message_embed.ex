defmodule Colloq.Messaging.MessageEmbed do
  @moduledoc """
  Open Graph link preview for a chat message.

  Written asynchronously by `Colloq.Workers.MessageEmbedWorker` — a message is
  never held up waiting on someone else's server — and rendered as a card under
  the bubble. Media URLs (images, video, YouTube…) are detected from the body at
  render time and don't go through here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_embeds" do
    field :url, :string
    field :host, :string
    field :title, :string
    field :description, :string
    field :image_url, :string

    belongs_to :message, Colloq.Messaging.Message

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(embed, attrs) do
    embed
    |> cast(attrs, [:url, :host, :title, :description, :image_url, :message_id])
    |> validate_required([:url, :host, :message_id])
    |> unique_constraint([:message_id, :url])
  end
end
