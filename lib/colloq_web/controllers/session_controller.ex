defmodule ColloqWeb.SessionController do
  use ColloqWeb, :controller

  @moduledoc """
  Controller for session management.
  Used by LiveView login to set session data (LiveView cannot modify sessions directly).
  """

  @doc """
  Logs the user out by dropping the whole session, then redirects home.
  """
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end

  @doc """
  Standard login — verifies the signed login token minted by the LiveView
  (which already authenticated the user) and establishes the session.
  """
  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(ColloqWeb.Endpoint, "login", token, max_age: 120) do
      {:ok, user_id} ->
        conn
        |> put_session(:user_id, to_string(user_id))
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "El enlace de acceso expiró. Iniciá sesión de nuevo.")
        |> redirect(to: "/login")
    end
  end

  @doc """
  Login for users requiring 2FA — verifies the signed token and stores the
  user id under pending_2fa_user_id, then redirects to the 2FA verification page.
  """
  def create_with_2fa(conn, %{"token" => token}) do
    case Phoenix.Token.verify(ColloqWeb.Endpoint, "pending_2fa", token, max_age: 120) do
      {:ok, user_id} ->
        conn
        |> put_session(:pending_2fa_user_id, to_string(user_id))
        |> redirect(to: "/2fa")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "El enlace de acceso expiró. Iniciá sesión de nuevo.")
        |> redirect(to: "/login")
    end
  end

  @doc """
  Finalizes a 2FA login. The TwoFactor LiveView, after verifying the TOTP code,
  redirects here with a short-lived signed token. We verify the token (which only
  that LiveView could have produced) and then establish the full session.
  """
  def finalize_2fa(conn, %{"token" => token}) do
    case Phoenix.Token.verify(ColloqWeb.Endpoint, "2fa_complete", token, max_age: 120) do
      {:ok, user_id} ->
        conn
        |> delete_session(:pending_2fa_user_id)
        |> put_session(:user_id, to_string(user_id))
        |> put_session(:_2fa_verified, true)
        |> redirect(to: "/")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "La verificación expiró. Iniciá sesión de nuevo.")
        |> redirect(to: "/login")
    end
  end
end
