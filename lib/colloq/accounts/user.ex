defmodule Colloq.Accounts.User do
  @moduledoc """
  User schema for Colloq.
  
  Trust levels (Discourse model):
  - TL0: New user (0 posts)
  - TL1: Basic (5 posts, 1 day)
  - TL2: Member (15 posts, 3 days)
  - TL3: Regular (30 posts, 7 days)
  - TL4: Leader (manual/admin)
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :username, :string
    field :display_name, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true

    # Trust system
    field :trust_level, :integer, default: 0
    field :posts_count, :integer, default: 0
    field :is_admin, :boolean, default: false

    # OAuth
    field :oauth_provider, :string
    field :oauth_uid, :string
    field :avatar_url, :string

    # Profile
    field :bio, :string
    field :location, :string
    field :website, :string

    # Preferences
    field :theme, :string, default: "dark"
    field :locale, :string, default: "es"
    field :notifications_enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :display_name, :password, :password_confirmation])
    |> validate_required([:email, :username, :password])
    |> validate_email()
    |> validate_username()
    |> validate_password()
    |> unique_constraint(:email)
    |> unique_constraint(:username)
    |> put_password_hash()
  end

  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :display_name, :bio, :location, :website,
      :theme, :locale, :notifications_enabled, :avatar_url
    ])
    |> validate_length(:display_name, max: 50)
    |> validate_length(:bio, max: 500)
    |> validate_url(:website)
  end

  def oauth_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :display_name, :oauth_provider, :oauth_uid, :avatar_url])
    |> validate_required([:email, :username, :oauth_provider, :oauth_uid])
    |> validate_email()
    |> validate_username()
    |> unique_constraint(:email)
    |> unique_constraint([:oauth_provider, :oauth_uid])
  end

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "email inválido")
    |> validate_length(:email, max: 160)
    |> update_change(:email, &String.downcase/1)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/, message: "solo letras, números y guiones bajos")
    |> update_change(:username, &String.downcase/1)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, message: "debe tener al menos 8 caracteres")
    |> validate_confirmation(:password, message: "las contraseñas no coinciden")
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    change(changeset, password_hash: Bcrypt.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if value == nil || value == "" || String.starts_with?(value, ["http://", "https://"]) do
        []
      else
        [{field, "debe comenzar con http:// o https://"}]
      end
    end)
  end
end
