defmodule Colloq.Messaging.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :body, :string
    field :read, :boolean, default: false
    field :read_at, :utc_datetime_usec

    belongs_to :conversation, Colloq.Messaging.Conversation
    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :conversation_id, :user_id])
    |> validate_required([:body, :conversation_id, :user_id])
    |> validate_length(:body, max: 10_000)
  end
end
