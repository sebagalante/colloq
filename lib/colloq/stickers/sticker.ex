defmodule Colloq.Stickers.Sticker do
  @moduledoc """
  A single sticker image belonging to a pack. Sent in chat as a message
  attachment (`attachment_type: "sticker"`) and inserted into posts as an
  inline image. Static or animated (PNG/GIF/WebP/APNG).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "stickers" do
    field :image_url, :string
    field :keywords, :string
    field :position, :integer, default: 0

    belongs_to :pack, Colloq.Stickers.Pack
    belongs_to :created_by, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sticker, attrs) do
    sticker
    |> cast(attrs, [:image_url, :keywords, :position, :pack_id, :created_by_id])
    |> validate_required([:image_url, :pack_id])
    |> foreign_key_constraint(:pack_id)
  end
end
