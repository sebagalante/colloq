defmodule Colloq.GeoIP do
  @moduledoc """
  Country/city lookups for IP addresses, from a MaxMind GeoLite2 City database.

  Backed by `locus`, a pure-Elixir MMDB reader: the database is held in memory,
  so a lookup is a map read, not a query.

  Two ways to supply the database, both optional:

    * `MAXMIND_LICENSE_KEY` — locus downloads GeoLite2-City from MaxMind and
      keeps it updated (they publish weekly).
    * `GEOLITE2_CITY_PATH` — a `.mmdb` on disk, for deploys that ship the file
      themselves or run without outbound access.

  With neither set the loader simply doesn't start and every lookup returns
  `:error`. Geolocation is decoration on an admin screen; it must never be a
  reason the app won't boot.

  Accuracy is "right country, plausible city" — good enough to notice an
  account logging in from three continents in a day, not good enough to act on
  automatically.
  """

  require Logger

  @loader :geolite2_city
  @asn_loader :geolite2_asn

  @doc """
  Child spec for the locus loader, or `nil` when no database is configured.

  `Colloq.Application` filters the nil out, which is how "no license key, no
  geolocation, app still boots" is expressed.
  """
  def child_spec_or_nil do
    case source() do
      nil -> nil
      {load_from, opts} -> :locus.loader_child_spec(@loader, load_from, opts)
    end
  end

  @doc """
  Child spec for the ASN loader, or nil when no ASN database is configured.

  Separate from the City database because they are separate MaxMind editions and
  either can be present without the other. ASN answers "is this a hosting
  provider?", which is a far better bot signal than the country is — a bot in
  `ap-southeast-1` and a fan in Singapore share a country but never an ASN.
  """
  def asn_child_spec_or_nil do
    case asn_source() do
      nil -> nil
      {load_from, opts} -> :locus.loader_child_spec(@asn_loader, load_from, opts)
    end
  end

  @doc "True when a database is configured (not necessarily loaded yet)."
  def configured?, do: source() != nil

  @doc "True when an ASN database is configured."
  def asn_configured?, do: asn_source() != nil

  @doc """
  Looks up the network an IP belongs to.

  Returns `{:ok, %{asn: 16509, org: "AMAZON-02"}}` or `:error`. The org string is
  what makes a signup worth a second look: "AMAZON-02" is a server, "Telecom
  Argentina" is a person.
  """
  def lookup_asn(nil), do: :error

  def lookup_asn(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> :error
      chars -> chars |> to_string() |> lookup_asn()
    end
  end

  def lookup_asn(ip) when is_binary(ip) do
    if asn_configured?() do
      case :locus.lookup(@asn_loader, String.to_charlist(ip)) do
        {:ok, entry} ->
          {:ok,
           %{
             asn: entry["autonomous_system_number"],
             org: entry["autonomous_system_organization"]
           }}

        _ ->
          :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  def lookup_asn(_), do: :error

  @doc """
  Looks an IP up. Accepts a string or an `:inet` tuple (`conn.remote_ip`).

  Returns `{:ok, %{country_code: "AR", country: "Argentina", city: "Rosario"}}`
  — any of which may be nil — or `:error` when the database isn't loaded, the
  address is private/unknown, or the input isn't an IP at all.
  """
  def lookup(nil), do: :error

  def lookup(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> :error
      chars -> chars |> to_string() |> lookup()
    end
  end

  def lookup(ip) when is_binary(ip) do
    if configured?() do
      case :locus.lookup(@loader, String.to_charlist(ip)) do
        {:ok, entry} -> {:ok, normalize(entry)}
        _ -> :error
      end
    else
      :error
    end
  rescue
    # A lookup before the loader has finished its first download raises; that's
    # a "not yet", not something worth failing an admin page over.
    _ -> :error
  end

  def lookup(_), do: :error

  @doc """
  `"AR · Rosario"` for display, or nil when there's nothing useful to show.
  """
  def describe(ip) do
    case lookup(ip) do
      {:ok, %{country_code: nil, city: nil}} -> nil
      {:ok, %{country_code: code, city: nil}} -> code
      {:ok, %{country_code: nil, city: city}} -> city
      {:ok, %{country_code: code, city: city}} -> "#{code} · #{city}"
      :error -> nil
    end
  end

  # MMDB entries are nested maps keyed by binaries, with localized name maps.
  defp normalize(entry) do
    %{
      country_code: get_in(entry, ["country", "iso_code"]),
      country: name(entry, "country"),
      city: name(entry, "city")
    }
  end

  defp name(entry, key) do
    names = get_in(entry, [key, "names"]) || %{}
    # Spanish first — the forum is Spanish — then English, then whatever exists.
    names["es"] || names["en"] || names |> Map.values() |> List.first()
  end

  # `{load_from, opts}` in locus's terms: a bare path is a filesystem source,
  # `{:maxmind, edition}` downloads (and keeps updating) from MaxMind.
  defp source do
    config = Application.get_env(:colloq, __MODULE__, [])

    cond do
      path = presence(config[:path]) ->
        {path, []}

      key = presence(config[:license_key]) ->
        {{:maxmind, "GeoLite2-City"}, [license_key: key, update_period: :timer.hours(24)]}

      true ->
        nil
    end
  end

  defp asn_source do
    config = Application.get_env(:colloq, __MODULE__, [])

    cond do
      path = presence(config[:asn_path]) ->
        {path, []}

      key = presence(config[:license_key]) ->
        {{:maxmind, "GeoLite2-ASN"}, [license_key: key, update_period: :timer.hours(24)]}

      true ->
        nil
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
