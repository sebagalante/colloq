defmodule ColloqWeb.UserAuth do
  import Phoenix.LiveView
  import Phoenix.Component

  @moduledoc """
  Authentication helpers for LiveViews and controllers.
  """

  alias Colloq.Accounts

  def on_mount(:default, _params, session, socket) do
    socket =
      case session["user_id"] do
        nil -> assign(socket, current_user: nil)
        user_id -> assign(socket, current_user: Accounts.get_user!(user_id))
      end

    {:cont, socket}
  end

  def on_mount(:require_user, _params, session, socket) do
    case session["user_id"] do
      nil ->
        socket =
          socket
          |> put_flash(:error, "Debes iniciar sesión para acceder a esta página.")
          |> redirect(to: "/login")

        {:halt, socket}

      user_id ->
        {:cont, assign(socket, current_user: Accounts.get_user!(user_id))}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket =
      case session["user_id"] do
        nil ->
          socket
          |> put_flash(:error, "Acceso denegado.")
          |> redirect(to: "/")

        user_id ->
          user = Accounts.get_user!(user_id)

          if user.is_admin do
            assign(socket, current_user: user)
          else
            socket
            |> put_flash(:error, "Acceso denegado.")
            |> redirect(to: "/")
          end
      end

    {:halt, socket}
  end

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)

    if user_id do
      user = Accounts.get_user(user_id)
      assign(conn, :current_user, user)
    else
      assign(conn, :current_user, nil)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "Debes iniciar sesión.")
      |> Phoenix.Controller.redirect(to: "/login")
      |> halt()
    end
  end

  def require_admin_user(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && user.is_admin do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "Acceso denegado.")
      |> Phoenix.Controller.redirect(to: "/")
      |> halt()
    end
  end
end
