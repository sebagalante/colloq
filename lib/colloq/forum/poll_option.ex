defmodule Colloq.Forum.PollOption do
  @moduledoc """
  An option within a poll.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "poll_options" do
    field :text, :string
    field :position, :integer, default: 0

    belongs_to :poll, Colloq.Forum.Poll
    has_many :votes, Colloq.Forum.PollVote

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(option, attrs) do
    option
    |> cast(attrs, [:text, :position, :poll_id])
    |> validate_required([:text, :poll_id])
    |> validate_length(:text, min: 1, max: 200)
  end
end
