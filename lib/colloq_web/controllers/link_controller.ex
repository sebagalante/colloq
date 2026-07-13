defmodule ColloqWeb.LinkController do
  use ColloqWeb, :controller

  @moduledoc false
  # /go?url= — link redirect with click tracking.

  # Allowed external domains for redirects (optional, empty = allow all http/https)
  @allowed_domains []

  def redirect(conn, %{"url" => url}) do
    if valid_redirect_url?(url) do
      conn
      |> Phoenix.Controller.redirect(external: url)
    else
      conn
      |> put_status(400)
      |> json(%{error: "URL no permitida"})
    end
  end

  def redirect(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "url parameter required"})
  end

  defp valid_redirect_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if Enum.empty?(@allowed_domains) do
          true
        else
          host in @allowed_domains
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
