defmodule ColloqWeb.Plugs.UploadHeaders do
  @moduledoc """
  Security headers for user-uploaded files served out of priv/static.

  `Plug.Static` is mounted in the endpoint *before* the router, so the CSP set
  by `put_secure_browser_headers/2` in the browser pipeline never reaches these
  responses — uploads went out with no security headers at all. That made a
  user-uploaded SVG a stored XSS: navigating straight to `/uploads/x.svg`
  renders it as a document on our origin and runs any script inside it.

  The fix that actually holds is the CSP `sandbox` directive: unlike an iframe
  `sandbox` attribute, which only constrains files *we* choose to embed, this
  travels with the response and so applies when the victim opens the link
  directly. Without `allow-scripts` no script runs, whatever the file contains.

  Must be plugged ahead of `Plug.Static`: it sets response headers on the conn,
  which `Plug.Static` preserves when it sends the file. Requests for paths that
  don't exist fall through to the router, which overwrites the CSP with the
  normal browser one — put_resp_header replaces rather than appends, so error
  pages are unaffected.
  """
  import Plug.Conn

  alias Colloq.Media.Sniff

  # 'none' everywhere plus sandbox; inline styles stay allowed so a legitimate
  # SVG still looks right when opened on its own. This is irrelevant to files
  # loaded as subresources (an <img> never runs script regardless) and only
  # bites on direct navigation, which is exactly the attack.
  @csp "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox"

  @prefix "uploads"

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: [@prefix | rest]} = conn, _opts) when rest != [] do
    conn
    |> put_resp_header("content-security-policy", @csp)
    # Stops a mislabelled file being re-interpreted as something executable.
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> maybe_force_download(List.last(rest))
  end

  def call(conn, _opts), do: conn

  defp maybe_force_download(conn, filename) do
    case filename |> Path.extname() |> Sniff.disposition_for_extension() do
      :attachment -> put_resp_header(conn, "content-disposition", "attachment")
      :inline -> conn
    end
  end
end
