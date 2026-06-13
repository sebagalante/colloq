defmodule ColloqWeb.Plugs.VpnOnly do
  @moduledoc """
  Restricts /admin/* routes to IPs in ADMIN_ALLOWED_CIDRS.
  
  CIDRs are configured in runtime.exs from ADMIN_ALLOWED_CIDRS env var.
  Format: comma-separated list of CIDR blocks (e.g., "10.0.0.0/8,192.168.1.0/24")
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    allowed_cidrs = Application.get_env(:colloq, :admin_allowed_cidrs, [])
    remote_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    if allowed?(conn.remote_ip, allowed_cidrs) do
      conn
    else
      Logger.warning("Admin access denied from IP: #{remote_ip}")

      conn
      |> put_status(403)
      |> Phoenix.Controller.put_view(ColloqWeb.ErrorHTML)
      |> Phoenix.Controller.render(:"403")
      |> halt()
    end
  end

  defp allowed?(_ip, []), do: true  # Allow all if not configured (dev safety)

  defp allowed?(ip, cidrs) when is_list(cidrs) do
    Enum.any?(cidrs, fn cidr ->
      case parse_cidr(cidr) do
        {:ok, {network, mask_bits}} -> in_cidr?(ip, network, mask_bits)
        {:error, _} -> false
      end
    end)
  end

  defp parse_cidr(cidr_string) do
    case String.split(cidr_string, "/") do
      [ip_str, mask_str] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_str)),
             {mask_bits, ""} <- Integer.parse(mask_str) do
          {:ok, {ip, mask_bits}}
        else
          _ -> {:error, :invalid_cidr}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp in_cidr?(ip, network, mask_bits) do
    ip_int = ip_to_integer(ip)
    network_int = ip_to_integer(network)
    mask = bnot(:erlang.bsl(1, 32 - mask_bits) - 1)

    (ip_int &&& mask) == (network_int &&& mask)
  end

  defp ip_to_integer({a, b, c, d}) do
    :erlang.bsl(a, 24) + :erlang.bsl(b, 16) + :erlang.bsl(c, 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    :erlang.bsl(a, 112) + :erlang.bsl(b, 96) + :erlang.bsl(c, 80) + :erlang.bsl(d, 64) +
      :erlang.bsl(e, 48) + :erlang.bsl(f, 32) + :erlang.bsl(g, 16) + h
  end
end
