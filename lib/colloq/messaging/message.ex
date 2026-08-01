defmodule Colloq.Messaging.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :body, :string
    field :read, :boolean, default: false
    field :read_at, :utc_datetime_usec
    field :sticker_url, :string
    field :deleted_at, :utc_datetime_usec

    belongs_to :conversation, Colloq.Messaging.Conversation
    belongs_to :user, Colloq.Accounts.User
    belongs_to :reply_to, Colloq.Messaging.Message
    has_many :embeds, Colloq.Messaging.MessageEmbed

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :conversation_id, :user_id, :sticker_url, :reply_to_id])
    |> validate_required([:conversation_id, :user_id])
    |> validate_length(:body, max: 10_000)
    |> validate_body_or_sticker()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:reply_to_id)
  end

  # A message must carry either text or a sticker (or both).
  defp validate_body_or_sticker(changeset) do
    body = get_field(changeset, :body)
    sticker = get_field(changeset, :sticker_url)

    if (is_nil(body) or body == "") and (is_nil(sticker) or sticker == "") do
      add_error(changeset, :body, "can't be blank without a sticker")
    else
      changeset
    end
  end
end
