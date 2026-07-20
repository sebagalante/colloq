defmodule Colloq.Reads.TopicRead do
  @moduledoc "Tracks the highest post_number a user has read in a topic."
  use Ecto.Schema
  import Ecto.Changeset

  schema "topic_reads" do
    field :last_read_post_number, :integer, default: 0
    belongs_to :user, Colloq.Accounts.User
    belongs_to :topic, Colloq.Forum.Topic

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(read, attrs) do
    read
    |> cast(attrs, [:user_id, :topic_id, :last_read_post_number])
    |> validate_required([:user_id, :topic_id, :last_read_post_number])
    |> unique_constraint([:user_id, :topic_id])
  end
end
