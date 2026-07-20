defmodule Colloq.Forum.Poll do
  @moduledoc """
  Poll attached to a post.

  A poll has a question and multiple options. Users vote on options.
  If `multiple` is true, users can select multiple options.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "polls" do
    field :question, :string
    field :closed, :boolean, default: false
    field :closed_at, :utc_datetime_usec
    field :multiple, :boolean, default: false
    field :anonymous, :boolean, default: false

    belongs_to :post, Colloq.Forum.Post
    has_many :options, Colloq.Forum.PollOption, preload_order: [:position]
    has_many :votes, Colloq.Forum.PollVote

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(poll, attrs) do
    poll
    |> cast(attrs, [:question, :multiple, :anonymous, :post_id])
    |> validate_required([:question, :post_id])
    |> validate_length(:question, min: 3, max: 300)
  end

  def close_changeset(poll) do
    poll
    |> change(closed: true, closed_at: DateTime.utc_now())
  end
end
