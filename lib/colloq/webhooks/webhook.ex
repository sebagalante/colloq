defmodule Colloq.Webhooks.Webhook do
  @moduledoc """
  User-configured webhook schema.

  Receives HTTP notifications when events occur
  on the platform (goals, new posts, etc.).
  """
  use Ecto.Schema
  import Ecto.Changeset
  import ColloqWeb.Gettext

  schema "webhooks" do
    field :url, :string
    field :secret, :string
    field :events, {:array, :string}, default: []
    field :active, :boolean, default: true
    field :last_delivery_at, :utc_datetime_usec
    field :last_status, :string
    field :last_response, :string

    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:url, :secret, :events, :active, :user_id])
    |> validate_required([:url, :user_id])
    |> validate_format(:url, ~r/^https?:\/\/.+/, message: gettext("must be a valid URL"))
    |> generate_secret()
  end

  def delivery_changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:last_delivery_at, :last_status, :last_response])
  end

  defp generate_secret(changeset) do
    case get_change(changeset, :secret) do
      nil ->
        if get_field(changeset, :secret) do
          changeset
        else
          put_change(changeset, :secret, generate_random_secret())
        end

      _ ->
        changeset
    end
  end

  defp generate_random_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
