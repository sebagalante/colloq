defmodule Colloq.Messaging do
  @moduledoc """
  Direct messaging context.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Messaging.{Conversation, Message}

  def list_conversations(user_id) do
    Conversation
    |> where([c], c.user1_id == ^user_id or c.user2_id == ^user_id)
    |> preload([:user1, :user2, :last_message])
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  def get_conversation!(id), do: Repo.get!(Conversation, id) |> Repo.preload([:messages, :user1, :user2])

  def find_or_create_conversation(user1_id, user2_id) do
    [min_id, max_id] = Enum.sort([user1_id, user2_id])

    case Repo.get_by(Conversation, user1_id: min_id, user2_id: max_id) do
      nil ->
        %Conversation{}
        |> Conversation.changeset(%{user1_id: min_id, user2_id: max_id})
        |> Repo.insert()

      conv ->
        {:ok, conv}
    end
  end

  def send_message(conversation_id, %Colloq.Accounts.User{} = user, body) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation_id,
      user_id: user.id,
      body: body
    })
    |> Repo.insert()
  end

  def mark_read!(conversation_id, user_id) do
    Message
    |> where(conversation_id: ^conversation_id)
    |> where([m], m.user_id != ^user_id)
    |> where(read: false)
    |> Repo.update_all(set: [read: true, read_at: DateTime.utc_now()])
  end
end
