defmodule Colloq.Messaging.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    belongs_to :user1, Colloq.Accounts.User
    belongs_to :user2, Colloq.Accounts.User
    belongs_to :last_message, Colloq.Messaging.Message

    field :user1_deleted_at, :utc_datetime_usec
    field :user2_deleted_at, :utc_datetime_usec

    has_many :messages, Colloq.Messaging.Message

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user1_id, :user2_id, :last_message_id, :user1_deleted_at, :user2_deleted_at])
    |> validate_required([:user1_id, :user2_id])
    |> unique_constraint([:user1_id, :user2_id])
  end
end
