defmodule Colloq.PushSubscriptions.PushSubscription do
  @moduledoc """
  Web push notification subscription schema.

  Stores the endpoint, encryption keys (p256dh, auth),
  and the teams the user is subscribed to.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :team_ids, {:array, :integer}, default: []
    field :preferences, :map, default: %{}

    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [
      :endpoint, :p256dh, :auth, :team_ids, :preferences, :user_id
    ])
    |> validate_required([:endpoint, :p256dh, :auth, :user_id])
    |> unique_constraint(:endpoint, name: :push_subscriptions_endpoint_index)
    |> foreign_key_constraint(:user_id)
  end
end
