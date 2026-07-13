defmodule Colloq.Forum.PollVote do
  @moduledoc """
  A user's vote on a poll option.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "poll_votes" do
    belongs_to :poll, Colloq.Forum.Poll
    belongs_to :poll_option, Colloq.Forum.PollOption
    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:poll_id, :poll_option_id, :user_id])
    |> validate_required([:poll_id, :poll_option_id, :user_id])
    |> unique_constraint([:poll_id, :user_id, :poll_option_id])
  end
end
