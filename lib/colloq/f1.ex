defmodule Colloq.F1 do
  @moduledoc """
  Formula 1 data, from the Jolpica API.

  Jolpica is the community-run continuation of Ergast, which stopped updating
  after the 2024 Chinese Grand Prix. It keeps Ergast's response shape, needs no
  API key, and is current — the 2026 Belgian GP was queryable the same day it
  ran.

  Deliberately *not* OpenF1: that one is better for telemetry (throttle traces,
  team radio), which is not what someone typing `/f1` in a football forum wants.
  If live timing during a race ever lands here, OpenF1 is the right source for
  it and this module is the wrong place.

  Every reader returns `{:ok, data, :cached | :live}` so replies can say whether
  the numbers came from cache. Standings and results are cached 30 minutes; the
  season schedule for 6 hours, since a calendar barely moves.
  """

  require Logger

  @base "https://api.jolpi.ca/ergast/f1"
  @user_agent "Colloq/1.0 (foro Racing Club)"

  @results_ttl :timer.minutes(30)
  @schedule_ttl :timer.hours(6)

  @doc "Current season year, per the server clock."
  def season, do: Date.utc_today().year

  @doc """
  The next race that hasn't started yet, or `{:error, :season_over}` once the
  calendar is exhausted.
  """
  def next_race(year \\ nil) do
    today = Date.utc_today()

    with {:ok, races, source} <- schedule(year) do
      races
      |> Enum.filter(&(parse_date(&1["date"]) && Date.compare(parse_date(&1["date"]), today) != :lt))
      |> List.first()
      |> case do
        nil -> {:error, :season_over}
        race -> {:ok, race, source}
      end
    end
  end

  @doc "Full race calendar for the season."
  def schedule(year \\ nil) do
    y = year || season()

    fetch("/#{y}.json", "f1:schedule:#{y}", @schedule_ttl, fn body ->
      get_in(body, ["MRData", "RaceTable", "Races"]) || []
    end)
  end

  @doc "Results of the most recently completed race."
  def last_results(year \\ nil) do
    y = year || season()

    fetch("/#{y}/last/results.json", "f1:last:#{y}", @results_ttl, fn body ->
      get_in(body, ["MRData", "RaceTable", "Races"]) |> List.wrap() |> List.first()
    end)
    |> case do
      {:ok, nil, _} -> {:error, :no_results}
      other -> other
    end
  end

  @doc "Drivers' championship standings."
  def driver_standings(year \\ nil) do
    y = year || season()

    fetch("/#{y}/driverStandings.json", "f1:drivers:#{y}", @results_ttl, &standings_rows(&1, "DriverStandings"))
  end

  @doc "Constructors' championship standings."
  def constructor_standings(year \\ nil) do
    y = year || season()

    fetch(
      "/#{y}/constructorStandings.json",
      "f1:constructors:#{y}",
      @results_ttl,
      &standings_rows(&1, "ConstructorStandings")
    )
  end

  @doc """
  Every driver on this season's entry list (31 in 2026, counting reserves).
  """
  def drivers(year \\ nil) do
    y = year || season()

    fetch("/#{y}/drivers.json?limit=100", "f1:drivers_list:#{y}", @schedule_ttl, fn body ->
      get_in(body, ["MRData", "DriverTable", "Drivers"]) || []
    end)
  end

  @doc """
  Finds a driver from free text — "verstappen", "Max Verstappen", "ANTONELLI".

  Jolpica keys drivers by ids like `max_verstappen`, which nobody types, so the
  match runs over the season roster on surname first (what people actually
  write), then full name, then the id itself. Accents are folded, so "Pérez"
  and "perez" both land.

  Returns `{:ok, driver, source}`, or `{:error, :not_found}`.
  """
  def find_driver(query, year \\ nil) do
    needle = normalize(query)

    with true <- needle != "",
         {:ok, roster, source} <- drivers(year) do
      roster
      |> Enum.find(&driver_matches?(&1, needle))
      |> case do
        nil -> {:error, :not_found}
        driver -> {:ok, driver, source}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp driver_matches?(driver, needle) do
    surname = normalize(driver["familyName"])
    full = normalize("#{driver["givenName"]} #{driver["familyName"]}")
    id = normalize(String.replace(to_string(driver["driverId"]), "_", " "))

    # `contains?` on the surname so "verstappen" matches and "max verstappen"
    # still does, without matching every driver on a one-letter query.
    String.length(needle) >= 3 and
      (surname == needle or full == needle or id == needle or
         String.contains?(surname, needle) or String.contains?(id, needle))
  end

  @doc """
  A driver's races this season, oldest first, each with their own result.

  Returns `{:ok, [%{race: ..., result: ...}], source}`.
  """
  def driver_season(driver_id, year \\ nil) do
    y = year || season()

    fetch(
      "/#{y}/drivers/#{driver_id}/results.json?limit=100",
      "f1:driver_season:#{y}:#{driver_id}",
      @results_ttl,
      fn body ->
        (get_in(body, ["MRData", "RaceTable", "Races"]) || [])
        |> Enum.map(fn race ->
          %{race: Map.delete(race, "Results"), result: List.first(race["Results"] || [])}
        end)
        |> Enum.reject(&is_nil(&1.result))
      end
    )
  end

  @doc """
  Season totals derived from `driver_season/2` rows: points, wins, podiums,
  best finish, poles and retirements.

  Derived rather than fetched because Jolpica has no per-driver summary
  endpoint — `/drivers/{id}/driverStandings.json` returns nothing usable.
  """
  def season_summary(rows) when is_list(rows) do
    positions =
      rows
      |> Enum.map(&int(&1.result["position"]))
      |> Enum.reject(&is_nil/1)

    %{
      races: length(rows),
      points: rows |> Enum.map(&num(&1.result["points"])) |> Enum.sum(),
      wins: Enum.count(positions, &(&1 == 1)),
      podiums: Enum.count(positions, &(&1 <= 3)),
      poles: Enum.count(rows, &(int(&1.result["grid"]) == 1)),
      best: if(positions == [], do: nil, else: Enum.min(positions)),
      # "Finished" and "+1 Lap" both mean they saw the flag; anything else is a
      # retirement, which is the number a fan actually wants.
      dnf: Enum.count(rows, &retired?(&1.result["status"]))
    }
  end

  defp retired?(nil), do: false
  defp retired?("Finished"), do: false
  defp retired?(status), do: not String.starts_with?(status, "+")

  defp int(nil), do: nil

  defp int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp num(value) do
    case Float.parse(to_string(value)) do
      {f, _} -> f
      _ -> 0.0
    end
  end

  defp normalize(text) do
    text
    |> to_string()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp standings_rows(body, key) do
    body
    |> get_in(["MRData", "StandingsTable", "StandingsLists"])
    |> List.wrap()
    |> List.first()
    |> case do
      nil -> []
      list -> Map.get(list, key, [])
    end
  end

  # --- HTTP + cache ----------------------------------------------------------

  defp fetch(path, cache_key, ttl, extract) do
    case Cachex.get(:forum_cache, cache_key) do
      {:ok, cached} when not is_nil(cached) ->
        {:ok, cached, :cached}

      _ ->
        case get(path) do
          {:ok, body} ->
            data = extract.(body)
            Cachex.put(:forum_cache, cache_key, data, ttl: ttl)
            {:ok, data, :live}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp get(path) do
    case Req.get(@base <> path,
           headers: %{"user-agent" => @user_agent, "accept" => "application/json"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("[F1] #{path} -> HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[F1] #{path} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  @doc """
  Race start in Argentine time (UTC-3) as `{date_string, time_string}`.

  Jolpica gives `date` and an optional `time` in UTC; without a time only the
  date is known, so the caller shows the day alone rather than inventing 00:00.
  """
  def local_start(%{"date" => date, "time" => time}) when is_binary(time) do
    with {:ok, dt, _} <- DateTime.from_iso8601("#{date}T#{String.replace(time, "Z", "")}Z") do
      local = DateTime.add(dt, -3 * 3600, :second)
      {Calendar.strftime(local, "%d/%m"), Calendar.strftime(local, "%H:%M")}
    else
      _ -> {short_date(date), nil}
    end
  end

  def local_start(%{"date" => date}), do: {short_date(date), nil}
  def local_start(_), do: {"", nil}

  defp short_date(date) do
    case parse_date(date) do
      nil -> to_string(date)
      d -> Calendar.strftime(d, "%d/%m")
    end
  end
end
