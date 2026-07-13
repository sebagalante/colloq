defmodule ColloqWeb.Plugs.RequirePermission do
  @moduledoc """
  Plug that checks if the current user has a specific permission.

  ## Usage

      plug ColloqWeb.Plugs.RequirePermission, :view_dashboard
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Colloq.Permissions

  def init(permission), do: permission

  def call(conn, permission) do
    user = conn.assigns[:current_user]

    if user && Permissions.can?(user, permission) do
      conn
    else
      conn
      |> put_flash(:error, "Acceso denegado.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
