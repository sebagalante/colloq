defmodule Colloq.Messaging.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :body, :string
    field :read, :boolean, default: false
    field :read_at, :utc_datetime_usec
    field :attachment_url, :string
    field :attachment_name, :string
    field :attachment_type, :string
    field :deleted_at, :utc_datetime_usec

    belongs_to :conversation, Colloq.Messaging.Conversation
    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :body,
      :conversation_id,
      :user_id,
      :attachment_url,
      :attachment_name,
      :attachment_type
    ])
    |> validate_required([:conversation_id, :user_id])
    |> validate_length(:body, max: 10_000)
    |> validate_body_or_attachment()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
  end

  # A message must carry either text or an attachment (or both).
  defp validate_body_or_attachment(changeset) do
    body = get_field(changeset, :body)
    attachment = get_field(changeset, :attachment_url)

    if (is_nil(body) or body == "") and (is_nil(attachment) or attachment == "") do
      add_error(changeset, :body, "can't be blank without an attachment")
    else
      changeset
    end
  end
end
