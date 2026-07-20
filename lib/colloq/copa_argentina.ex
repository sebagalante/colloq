defmodule Colloq.CopaArgentina do
  @moduledoc """
  Copa Argentina fixtures and results, from FotMob's league feed.

  **This is an undocumented endpoint.** FotMob publishes no public API; this is
  the JSON its own site calls (`/api/data/leagues?id=9305` — note the `data`
  segment, `/api/leagues` returns the SPA shell). It can change or disappear
  without notice, so every reader fails soft and the whole payload is cached
  for 30 minutes: one request per half hour regardless of how many people ask.

  Only Copa Argentina. Other competitions come from Sofascore
  (`Colloq.Sofascore`), and mixing the two providers behind one module would
  make it impossible to tell which one broke.
  """

  require Logger

  @league_id 9305
  @base "https://www.fotmob.com/api/data/leagues"
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  @cache_key "copa_argentina:league"
  @ttl :timer.minutes(30)

  @doc """
  Every match of the current edition, oldest first.

  Returns `{:ok, matches, :cached | :live}` or `{:error, reason}`.
  """
  def matches do
    with {:ok, payload, source} <- league() do
      matches =
        payload
        |> get_in(["fixtures", "allMatches"])
        |> List.wrap()
        |> Enum.sort_by(&kickoff_unix/1)

      {:ok, matches, source}
    end
  end

  @doc "Matches already played, most recent first."
  def results(limit \\ 12) do
    with {:ok, all, source} <- matches() do
      played =
        all
        |> Enum.filter(&finished?/1)
        |> Enum.reverse()
        |> Enum.take(limit)

      {:ok, played, source}
    end
  end

  @doc "Matches not yet played, soonest first."
  def upcoming(limit \\ 12) do
    with {:ok, all, source} <- matches() do
      {:ok, all |> Enum.reject(&finished?/1) |> Enum.take(limit), source}
    end
  end

  @doc "Competition name and season, for card headings."
  def details do
    with {:ok, payload, source} <- league() do
      {:ok,
       %{
         name: get_in(payload, ["details", "name"]) || "Copa Argentina",
         season: get_in(payload, ["details", "selectedSeason"])
       }, source}
    end
  end

  @doc "Whether a match has been played."
  def finished?(match), do: get_in(match, ["status", "finished"]) == true

  @doc "`\"2 - 0\"` for a played match, `nil` otherwise."
  def score(match), do: get_in(match, ["status", "scoreStr"])

  @doc """
  Round label. FotMob gives a bare number (`1`, `16`, `8`) meaning the number of
  teams left, so 16 is the round of 16 and 1 the final — rendering "Ronda 1"
  for the final would be actively wrong.
  """
  def round_name(match) do
    case match["roundName"] do
      1 -> "Final"
      2 -> "Semifinal"
      4 -> "Cuartos"
      8 -> "Octavos"
      16 -> "16avos"
      32 -> "32avos"
      n when is_integer(n) -> "Ronda #{n}"
      name when is_binary(name) -> name
      _ -> ""
    end
  end

  @doc """
  Kickoff in Argentine time (UTC-3) as `{date, time}`, e.g. `{"30/08", "21:00"}`.

  FotMob sends some fixtures at exactly 00:00Z, which is its placeholder for
  "date known, time not announced" — those return `nil` for the time rather
  than claiming a 21:00 kickoff that nobody scheduled.
  """
  def local_kickoff(match) do
    case parse_utc(get_in(match, ["status", "utcTime"])) do
      nil ->
        {"", nil}

      dt ->
        local = DateTime.add(dt, -3 * 3600, :second)
        time = if dt.hour == 0 and dt.minute == 0, do: nil, else: Calendar.strftime(local, "%H:%M")
        {Calendar.strftime(local, "%d/%m"), time}
    end
  end

  defp kickoff_unix(match) do
    case parse_utc(get_in(match, ["status", "utcTime"])) do
      nil -> 0
      dt -> DateTime.to_unix(dt)
    end
  end

  defp parse_utc(nil), do: nil

  defp parse_utc(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # --- fetch + cache ---------------------------------------------------------

  defp league do
    case Cachex.get(:forum_cache, @cache_key) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload, :cached}

      _ ->
        case get() do
          {:ok, payload} ->
            Cachex.put(:forum_cache, @cache_key, payload, ttl: @ttl)
            {:ok, payload, :live}

          error ->
            error
        end
    end
  end

  defp get do
    case Req.get("#{@base}?id=#{@league_id}",
           headers: %{"user-agent" => @user_agent, "accept" => "application/json"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      # An HTML body means FotMob served the SPA instead of JSON — usually the
      # sign that the undocumented endpoint moved.
      {:ok, %{status: 200}} ->
        Logger.warning("[CopaArgentina] non-JSON body — endpoint may have changed")
        {:error, :unexpected_payload}

      {:ok, %{status: status}} ->
        Logger.warning("[CopaArgentina] HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[CopaArgentina] request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
