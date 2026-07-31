defmodule Colloq.Accounts.User do
  @moduledoc """
  User schema for Colloq.

  Trust levels (adapted from Discourse for a football forum):
  - TL0: New user (0 posts) — 100 posts/day, 100 reactions/day
  - TL1: Basic (10 posts, 1 day) — 200 posts/day, 200 reactions/day
  - TL2: Member (50 posts, 7 days) — 500 posts/day, 500 reactions/day
  - TL3: Regular (200 posts, 30 days) — unlimited
  - TL4: Leader (manual/admin) — unlimited
  """
  use Ecto.Schema
  import Ecto.Changeset
  import ColloqWeb.Gettext

  schema "users" do
    field :email, :string
    field :username, :string
    field :display_name, :string
    # `redact: true` keeps these out of `inspect/1` output. Without it the
    # plaintext password reaches anywhere a changeset or struct gets inspected:
    # Ecto's debug logging on a constraint error, a crash report, or an
    # exception forwarded to an error tracker. The hash is redacted too — it
    # is not secret exactly, but a log aggregator is a poor place to leave
    # something crackable offline.
    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    # Trust system
    field :trust_level, :integer, default: 0
    field :posts_count, :integer, default: 0
    # Gamification: engagement points, recomputed by the "Recompute scores" automation.
    field :score, :integer, default: 0
    field :score_updated_at, :utc_datetime_usec
    field :is_admin, :boolean, default: false

    # Role-based access control
    # nil | "moderator" | "admin" | "super_admin"
    field :role, :string

    # Two-factor authentication (TOTP)
    field :totp_secret, :binary
    field :totp_enabled, :boolean, default: false
    field :totp_backup_codes, {:array, :string}, default: []
    field :totp_last_used_at, :utc_datetime_usec
    field :totp_pending_secret, :binary

    # OAuth
    field :oauth_provider, :string
    field :oauth_uid, :string
    field :avatar_url, :string
    field :profile_header_url, :string
    field :card_background_url, :string

    # Profile
    field :bio, :string
    field :location, :string
    field :website, :string
    field :flair, :string

    # Preferences
    field :theme, :string, default: "dark"
    field :locale, :string, default: "es"
    field :notifications_enabled, :boolean, default: true
    field :allow_messages, :boolean, default: true

    # Moderation
    field :suspended_until, :utc_datetime_usec
    field :suspended_at, :utc_datetime_usec
    field :suspension_reason, :string
    field :banned, :boolean, default: false
    field :banned_at, :utc_datetime_usec
    field :ban_reason, :string
    field :warnings_count, :integer, default: 0
    field :last_warning_at, :utc_datetime_usec
    field :last_warning_reason, :string
    field :last_ip, :string
    field :last_login_at, :utc_datetime_usec

    # The address the account was created from, written once at signup.
    # `last_ip` is overwritten on every login, so it can't answer "where did
    # this come from?". Country/network are resolved from it at render time.
    field :signup_ip, :string
    field :silenced_until, :utc_datetime_usec
    field :silenced_at, :utc_datetime_usec
    field :silence_reason, :string

    # Virtual fields for moderation status checks
    field :suspended?, :boolean, default: false, virtual: true

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
      :username,
      :display_name,
      :bio,
      :location,
      :website,
      :theme,
      :locale,
      :notifications_enabled,
      :allow_messages,
      :avatar_url,
      :flair,
      :profile_header_url,
      :card_background_url
    ])
    |> validate_length(:display_name, max: 50)
    |> validate_length(:bio, max: 500)
    |> validate_length(:flair, max: 20)
    |> validate_url(:website)
    # Only runs when the username actually changes (Ecto skips validations for
    # unchanged fields), so editing other settings won't re-validate it.
    |> validate_username()
    |> unique_constraint(:username)
  end

  @doc """
  Changeset for admin role assignment (super_admin only).
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_inclusion(:role, [nil, "moderator", "admin", "super_admin"])
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
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: gettext("invalid email"))
    |> validate_length(:email, max: 160)
    |> update_change(:email, &String.downcase/1)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: gettext("letters, numbers and underscores only")
    )
    |> update_change(:username, &String.downcase/1)
  end

  @doc """
  Changeset for setting a new password on an existing user.

  The reset-password flow used to hash straight into `Ecto.Changeset.change/2`,
  which meant the rules enforced at registration did not apply to a reset —
  the two paths could drift apart. Both go through here now.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password])
    |> validate_password()
    |> put_password_hash()
  end

  # Bcrypt hashes at most the first 72 bytes and silently ignores the rest, so
  # a longer passphrase is not as strong as it looks — and the extra characters
  # would start counting if the algorithm ever changed, invalidating passwords
  # that used to work. Rejecting them outright keeps the stored hash and the
  # password the user typed in agreement.
  @max_password_bytes 72

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, message: gettext("must be at least 8 characters"))
    |> validate_length(:password,
      max: @max_password_bytes,
      count: :bytes,
      message: gettext("must be at most %{count} characters", count: @max_password_bytes)
    )
    |> validate_confirmation(:password, message: gettext("passwords do not match"))
  end

  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    change(changeset, password_hash: Bcrypt.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if value == nil || value == "" || String.starts_with?(value, ["http://", "https://"]) do
        []
      else
        [{field, gettext("must start with http:// or https://")}]
      end
    end)
  end

  @doc """
  Checks if the user is currently suspended (suspension hasn't expired).
  """
  def suspended?(%__MODULE__{suspended_until: nil}), do: false

  def suspended?(%__MODULE__{suspended_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  @doc """
  Checks if the user is currently silenced (silence hasn't expired).

  A silenced user can log in and read, but cannot post or reply.
  """
  def silenced?(%__MODULE__{silenced_until: nil}), do: false

  def silenced?(%__MODULE__{silenced_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  @doc """
  Checks if the user is banned or currently suspended.

  Note: silence is intentionally excluded — silenced users may still log in.
  """
  def blocked?(%__MODULE__{banned: true}), do: true
  def blocked?(user), do: suspended?(user)

  @doc """
  Returns a human-readable moderation status.
  """
  def moderation_status(%__MODULE__{banned: true}), do: :banned

  def moderation_status(%__MODULE__{} = user) do
    cond do
      suspended?(user) -> :suspended
      silenced?(user) -> :silenced
      true -> :active
    end
  end

  @doc """
  Returns the user's avatar URL if set (from OAuth), nil otherwise.
  """
  def avatar_url(%__MODULE__{avatar_url: url}) when is_binary(url) and url != "", do: url
  def avatar_url(_), do: nil
end
