defmodule Colloq.Moderation.SpamClassification do
  @moduledoc """
  A single ML spam screening: what the model scored a post, and what was done.

  `would_flag` and `acted` are deliberately separate. In shadow mode a post can
  be `would_flag: true, acted: false` — the model called it spam and nothing
  happened — which is exactly the row you want to read when deciding whether
  enforcing would have been safe.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "spam_classifications" do
    field :score, :float
    field :threshold, :float
    field :would_flag, :boolean, default: false
    field :mode, :string
    field :acted, :boolean, default: false

    belongs_to :post, Colloq.Forum.Post
    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:post_id, :user_id, :score, :threshold, :would_flag, :mode, :acted])
    # post_id is required when the row is written, but the column is nullable:
    # PrunePostsWorker eventually deletes the post and the FK nilifies, so the
    # score survives in the dashboard after the body is gone.
    |> validate_required([:post_id, :score, :threshold, :mode])
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
