defmodule ColloqWeb.Plugs.SecureHeaders do
  @moduledoc """
  Security headers for browser responses, with a nonce-based CSP in prod.

  Replaces the static `put_secure_browser_headers` call in the :browser
  pipeline so the CSP can carry a per-request nonce. The nonce is assigned to
  the conn (read back by this plug to build the header) and passed to the
  LiveView socket via `csp_nonce_assign_key` (see endpoint.ex), so both the
  root layout script tag and LiveView's own inline bootstrap scripts stay
  allowed.

  In prod this drops 'unsafe-inline' and 'unsafe-eval' from script-src: with
  them present, any injected inline script runs, which pairs badly with the
  user-upload SVG surface. Dev/test keep the permissive policy because
  live-reload injects unsigned inline scripts.

  Deploy note: in prod any *new* inline script must get `nonce={@csp_nonce}`
  (and new external widget hosts must be allow-listed in @prod_script_sources)
  or the browser blocks it — CSP violations fail closed and show up as console
  errors, so a broken page announces itself loudly.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_secure_browser_headers: 2]

  # External script hosts the site legitimately loads (X/Twitter embeds).
  @prod_script_sources ~w(https://platform.twitter.com https://cdn.syndication.twimg.com)

  # Dev/test: unchanged from the previous static policy (live-reload injects
  # unsigned inline scripts, so 'unsafe-inline'/'unsafe-eval' stay there).
  @dev_csp "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://platform.twitter.com https://cdn.syndication.twimg.com; style-src 'self' 'unsafe-inline' https://platform.twitter.com https://fonts.googleapis.com; img-src 'self' data: https:; font-src 'self' https://fonts.gstatic.com; connect-src 'self' ws: wss: https://syndication.twitter.com https://cdn.syndication.twimg.com; media-src 'self' https:; frame-src 'self' https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com https://platform.twitter.com https://twitter.com https://x.com https://open.spotify.com https://w.soundcloud.com https://www.facebook.com https://web.facebook.com https://www.instagram.com;"

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_secure_browser_headers(%{"content-security-policy" => csp(nonce)})
  end

  defp csp(nonce) when is_binary(nonce) do
    if Mix.env() == :prod do
      script_sources = Enum.join(["'self'", "'nonce-#{nonce}'"] ++ @prod_script_sources, " ")

      "default-src 'self'; " <>
        "script-src #{script_sources}; " <>
        "style-src 'self' 'unsafe-inline' https://platform.twitter.com https://fonts.googleapis.com; " <>
        "img-src 'self' data: https:; " <>
        "font-src 'self' https://fonts.gstatic.com; " <>
        "connect-src 'self' ws: wss: https://syndication.twitter.com https://cdn.syndication.twimg.com; " <>
        "media-src 'self' https:; " <>
        "frame-src 'self' https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com https://platform.twitter.com https://twitter.com https://x.com https://open.spotify.com https://w.soundcloud.com https://www.facebook.com https://web.facebook.com https://www.instagram.com;"
    else
      @dev_csp
    end
  end
end
