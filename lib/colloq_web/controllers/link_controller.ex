defmodule ColloqWeb.LinkController do
  use ColloqWeb, :controller

  @moduledoc false
  # /go?url= — link redirect with click tracking.

  # Allowed external domains for redirects. SECURITY: empty means DISABLED, not
  # "allow everything" — an empty allow-list used to fall through to allowing
  # all http/https, turning /go?url=… into a phishing redirector on our own
  # domain. Admins can enable the feature per environment via the
  # `allowed_redirect_domains` site setting (comma-separated, hosts match
  # exactly); the setting REPLACES this default, it never extends it.
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
        host in allowed_domains()

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # Read at request time (not a compile-time constant): the site setting is the
  # deploy knob, and an empty effective list disables the route entirely.
  defp allowed_domains do
    case Colloq.SiteSettings.get("allowed_redirect_domains") do
      nil ->
        @allowed_domains

      domains when is_binary(domains) ->
        String.split(domains, ",", trim: true) |> Enum.map(&String.trim/1)

      domains when is_list(domains) ->
        domains
    end
  end
end
