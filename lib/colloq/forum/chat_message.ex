defmodule Colloq.Forum.ChatMessage do
  @moduledoc """
  Real-time chat message schema associated with topics.

  Chat messages are short messages displayed in a
  side chat view, separate from forum posts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_messages" do
    field :body, :string

    belongs_to :topic, Colloq.Forum.Topic
    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :topic_id, :user_id])
    |> validate_required([:body, :topic_id, :user_id])
    |> validate_length(:body, min: 1, max: 1000)
  end
end
