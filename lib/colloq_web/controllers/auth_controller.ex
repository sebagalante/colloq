defmodule ColloqWeb.AuthController do
  use ColloqWeb, :controller

  @moduledoc false
  # OAuth callback controller — Google, GitHub, Discord.

  def callback(conn, %{"provider" => provider} = params) do
    conn
    |> put_flash(:error, "OAuth not configured for #{provider}")
    |> redirect(to: "/login")
  end

  def failure(conn, _params) do
    conn
    |> put_flash(:error, "Inicio de sesión cancelado o fallido.")
    |> redirect(to: "/login")
  end
end