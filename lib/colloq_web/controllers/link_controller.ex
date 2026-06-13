defmodule ColloqWeb.LinkController do
  use ColloqWeb, :controller

  @moduledoc false
  # /go?url= — link redirect with click tracking.

  def redirect(conn, %{"url" => url}) do
    conn
    |> Phoenix.Controller.redirect(external: url)
  end

  def redirect(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "url parameter required"})
  end
end