defmodule Colloq.HttpGuard do
  @moduledoc """
  SSRF guard for server-side fetches of user-supplied URLs.

  Posts, comments and DMs routinely carry links, and several workers fetch them
  (link unfurling, link validation). A URL in a post is attacker-controlled
  input like any other: without this check `http://169.254.169.254/…` (cloud
  metadata), `http://localhost:4000/admin/…` or `http://10.0.0.1/…` are all
  reachable from the app's network position, and scrape results (titles,
  descriptions) get stored and rendered — a semi-blind internal-read primitive.

  `validate/1` rejects anything that is not http(s), has no host, cannot be
  resolved, or resolves to a private/loopback/link-local/reserved address.
  DNS is resolved here so a hostname pointing at an internal IP is caught too,
  not just literal IPs.

  Known limitation: these checks run on the *initial* URL. `Req` follows
  redirects internally, and a remote host could 30x to an internal address.
  That residual risk is accepted because redirects to internal targets leak
  nothing through OG scraping unless the internal service echoes the request.
  """

  @type reason ::
          :not_binary | :bad_url | :bad_scheme | :no_host | :blocked_host | :unresolvable

  import Bitwise

  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        cond do
          blocked_hostname?(host) -> {:error, :blocked_host}
          true -> resolve_and_check(host)
        end

      # URI.parse/1 returns host: "" for URLs with an empty authority
      # ("file:///etc/passwd"), so both nil and "" land here.
      %URI{scheme: scheme} when is_binary(scheme) -> {:error, :bad_scheme}
      %URI{host: host} when host in [nil, ""] -> {:error, :no_host}
      _ -> {:error, :bad_url}
    end
  end

  def validate(_), do: {:error, :not_binary}

  @doc "Convenience predicate — true only when `validate/1` returns `:ok`."
  @spec safe_url?(term()) :: boolean()
  def safe_url?(url), do: validate(url) == :ok

  # Hostnames that need no DNS to be dangerous, or whose DNS this node
  # shouldn't be performing (mDNS/zeroconf lookups can hang).
  defp blocked_hostname?(host) do
    host = String.downcase(host)
    host == "localhost" or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local") or String.ends_with?(host, ".internal")
  end

  defp resolve_and_check(host) do
    charlist = String.to_charlist(host)

    ips =
      case :inet.parse_address(charlist) do
        {:ok, ip} ->
          [ip]

        _ ->
          Enum.flat_map([:a, :aaaa], fn type ->
            :inet_res.lookup(charlist, :in, type) || []
          end)
      end

    cond do
      ips == [] -> {:error, :unresolvable}
      Enum.any?(ips, &blocked_ip?/1) -> {:error, :blocked_host}
      true -> :ok
    end
  end

  # IPv4. Everything that isn't a normal unicast public address is rejected —
  # RFC 1918, loopback, link-local, CGNAT, multicast, reserved, "this network".
  defp blocked_ip?({a, b, c, _d}) do
    a == 0 or a == 10 or a == 127 or
      {a, b} == {169, 254} or {a, b} == {192, 168} or
      (a == 172 and b in 16..31) or
      (a == 100 and b in 64..127) or
      (a == 192 and b == 0 and c in [0, 2]) or
      {a, b, c} == {198, 51, 100} or {a, b, c} == {203, 0, 113} or
      (a == 198 and b in 18..19) or
      a in 224..255
  end

  # IPv6. fc00::/7 (ULA), fe80::/10 (link-local), :: (unspecified), ::1
  # (loopback), and IPv4-mapped addresses (::ffff:a.b.c.d), which are just
  # IPv4 private ranges wearing a disguise.
  defp blocked_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFC00..0xFDFF, do: true
  defp blocked_ip?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFE80..0xFEBF, do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0xffff, g, h}) do
    blocked_ip?({g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF})
  end

  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?(_ip), do: false
end
