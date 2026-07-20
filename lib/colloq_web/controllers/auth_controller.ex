defmodule ColloqWeb.AuthController do
  use ColloqWeb, :controller

  @moduledoc """
  OAuth callback controller — Google, Microsoft, Facebook, X (Twitter), Discord.

  Uses Ueberauth for the OAuth 2.0 flow. The callback receives the
  authenticated user info from the provider and creates or finds
  the local user account.
  """

  plug Ueberauth

  alias Colloq.Accounts

  @doc """
  Ueberauth callback — called after successful OAuth authentication.
  """
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    provider = to_string(auth.provider)
    uid = to_string(auth.uid)
    email = auth.info.email
    name = auth.info.name || auth.info.nickname || ""
    avatar = auth.info.image

    # Generate a username from email or nickname
    username = generate_username(email, auth.info.nickname, provider)

    attrs = %{
      "provider" => provider,
      "uid" => uid,
      "email" => email || "#{uid}@#{provider}.oauth",
      "username" => username,
      "display_name" => name,
      "avatar_url" => avatar
    }

    case Accounts.find_or_create_from_oauth(attrs) do
      {:ok, user} ->
        if Accounts.requires_2fa?(user) do
          conn
          |> put_session(:pending_2fa_user_id, user.id)
          |> redirect(to: "/2fa")
        else
          Accounts.record_login(user.id, conn.remote_ip)

          conn
          |> put_session(:user_id, user.id)
          |> put_flash(:info, gettext("Welcome!"))
          |> redirect(to: "/")
        end

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("Could not create account. Please try again."))
        |> redirect(to: "/login")
    end
  end

  @doc """
  Ueberauth failure — called when OAuth authentication fails.
  """
  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    message =
      case failure.errors do
        [%Ueberauth.Failure.Error{message: msg} | _] -> msg
        _ -> gettext("Authentication failed.")
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: "/login")
  end

  @doc """
  Fallback for when Ueberauth doesn't populate assigns.
  """
  def callback(conn, _params) do
    conn
    |> put_flash(:error, gettext("Authentication failed."))
    |> redirect(to: "/login")
  end

  def failure(conn, _params) do
    conn
    |> put_flash(:error, gettext("Authentication failed."))
    |> redirect(to: "/login")
  end

  defp generate_username(email, nickname, provider) do
    cond do
      nickname && nickname != "" ->
        slugify(nickname)

      email && email != "" ->
        email
        |> String.split("@")
        |> hd()
        |> slugify()

      true ->
        "#{provider}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.trim("_")
    |> String.slice(0, 30)
  end
end
