defmodule Colloq.Badges.UserBadge do
  @moduledoc """
  Join table linking users to badges.

  display_position controls the order of badges shown on a user's
  profile and posts (0-2, max 3 displayed).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_badges" do
    field :display_position, :integer, default: 0

    belongs_to :user, Colloq.Accounts.User
    belongs_to :badge, Colloq.Badges.Badge
    belongs_to :granted_by, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user_badge, attrs) do
    user_badge
    |> cast(attrs, [:user_id, :badge_id, :granted_by_id, :display_position])
    |> validate_required([:user_id, :badge_id])
    |> validate_number(:display_position, greater_than_or_equal_to: 0, less_than: 3)
    |> unique_constraint([:user_id, :badge_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:badge_id)
  end
end
