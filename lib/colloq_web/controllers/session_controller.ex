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
  Logs a suspended or banned user out and sends them to /login. The suspension
  status (and end date) ride in query params — not flash — so the banner is
  driven by the login LiveView's own assigns and can't be lost in the handoff.
  """
  def suspended(conn, _params) do
    user =
      case get_session(conn, :user_id) do
        nil -> nil
        id -> Colloq.Accounts.get_user(id)
      end

    conn
    |> delete_session(:user_id)
    |> delete_session(:_2fa_verified)
    |> delete_session(:pending_2fa_user_id)
    |> redirect(to: "/login?" <> URI.encode_query(suspension_params(user)))
  end

  defp suspension_params(%{banned: true}), do: %{"blocked" => "banned"}

  defp suspension_params(%{suspended_until: %DateTime{} = until}),
    do: %{"blocked" => "suspended", "until" => DateTime.to_iso8601(until)}

  defp suspension_params(_), do: %{"blocked" => "suspended"}

  @doc """
  Standard login — verifies the signed login token minted by the LiveView
  (which already authenticated the user) and establishes the session.
  """
  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(ColloqWeb.Endpoint, "login", token, max_age: 120) do
      {:ok, user_id} ->
        Colloq.Accounts.record_login(user_id, conn.remote_ip)

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
        Colloq.Accounts.record_login(user_id, conn.remote_ip)

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
