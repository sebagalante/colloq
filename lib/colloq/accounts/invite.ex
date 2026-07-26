defmodule Colloq.Accounts.Invite do
  @moduledoc """
  A single invitation to register, used when `registration_mode = "invite"`.

  The token travels in the signup link and is the only thing proving the holder
  was invited, so it is generated server-side and never accepted from user input
  on creation.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import ColloqWeb.Gettext

  schema "invites" do
    field :email, :string
    field :token, :string
    field :accepted_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec

    belongs_to :invited_by, Colloq.Accounts.User
    belongs_to :accepted_by, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a new invite for `email`. Token and expiry are set here rather than
  cast, so a caller can't pick its own token or push the expiry out.
  """
  def create_changeset(attrs, ttl_days) do
    %__MODULE__{}
    |> cast(attrs, [:email, :invited_by_id])
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    # Same shape check the registration form uses, so an invite can't be sent to
    # an address that could never sign up.
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: gettext("invalid email"))
    |> put_change(:token, generate_token())
    |> put_change(:expires_at, DateTime.add(DateTime.utc_now(), ttl_days * 24 * 3600, :second))
    |> unique_constraint(:token)
  end

  @doc "Marks the invite as accepted by `user`."
  def accept_changeset(invite, user) do
    change(invite, accepted_at: DateTime.utc_now(), accepted_by_id: user.id)
  end

  @doc "Stamps delivery time once the email worker has handed it off."
  def sent_changeset(invite) do
    change(invite, sent_at: DateTime.utc_now())
  end

  @doc "Still usable: not accepted and not past its expiry."
  def pending?(%__MODULE__{accepted_at: nil, expires_at: exp}),
    do: DateTime.compare(exp, DateTime.utc_now()) == :gt

  def pending?(%__MODULE__{}), do: false

  defp generate_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
