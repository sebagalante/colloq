defmodule Colloq.Accounts do
  @moduledoc """
  Accounts context for Colloq.
  
  Handles users, authentication, trust levels, and OAuth identity linking.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Accounts.User

  @doc """
  Get a user by ID.
  """
  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Get a user by username.
  """
  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Get a user by email.
  """
  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Register a new user with email/password.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticate by email and password.
  """
  def authenticate_user(email, password) do
    user = get_user_by_email(email)

    cond do
      user && Bcrypt.verify_pass(password, user.password_hash) ->
        {:ok, user}

      true ->
        # Timing-attack resistant: compute dummy hash
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  @doc """
  Update user settings.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update trust level (called by TrustPromotionWorker).
  """
  def update_trust_level(%User{} = user, new_level) when new_level in 0..4 do
    user
    |> Ecto.Changeset.change(trust_level: new_level)
    |> Repo.update()
  end

  @doc """
  List users eligible for trust level promotion.
  """
  def list_eligible_for_promotion(current_level, min_posts, min_days_since_registration) do
    cutoff = DateTime.utc_now() |> DateTime.add(-min_days_since_registration, :day)

    User
    |> where([u], u.trust_level == ^current_level)
    |> where([u], u.posts_count >= ^min_posts)
    |> where([u], u.inserted_at <= ^cutoff)
    |> Repo.all()
  end

  @doc """
  Increment post count for a user.
  """
  def increment_posts_count(%User{} = user) do
    user
    |> Ecto.Changeset.change(posts_count: user.posts_count + 1)
    |> Repo.update()
  end

  @doc """
  OAuth: Find or create user from OAuth data.
  """
  def find_or_create_from_oauth(%{"provider" => provider, "uid" => uid} = attrs) do
    case Repo.get_by(User, oauth_provider: provider, oauth_uid: to_string(uid)) do
      nil ->
        # New OAuth user
        %User{}
        |> User.oauth_changeset(attrs)
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end
end
