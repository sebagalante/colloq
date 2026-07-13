defmodule Colloq.Moderation.Flag do
  @moduledoc """
  Post flag (report) schema.

  A user flags a post with a reason. A moderator resolves it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "flags" do
    field :reason, :string
    field :resolved, :boolean, default: false
    field :resolved_at, :utc_datetime_usec
    field :resolution, :string

    belongs_to :post, Colloq.Forum.Post
    belongs_to :topic, Colloq.Forum.Topic
    belongs_to :user, Colloq.Accounts.User
    belongs_to :resolved_by, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [
      :reason, :resolved, :resolved_at, :resolution,
      :post_id, :topic_id, :user_id, :resolved_by_id
    ])
    |> validate_required([:reason, :post_id, :user_id])
    |> validate_inclusion(:reason, ~w(spam inappropriate off_topic harassment other))
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:user_id)
  end
end
