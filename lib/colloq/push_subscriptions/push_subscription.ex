defmodule Colloq.PushSubscriptions.PushSubscription do
  @moduledoc """
  Esquema de suscripción a notificaciones push web.

  Almacena el endpoint, las claves de cifrado (p256dh, auth)
  y los equipos a los que está suscrito el usuario.
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
