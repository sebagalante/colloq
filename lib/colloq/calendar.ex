defmodule Colloq.Calendar do
  @moduledoc """
  The match calendar behind `/calendario`: every match of a week, filtered to
  the teams and competitions the reader has switched on.

  Source is FotMob's matches-by-date feed (`/api/data/matches`), one request per
  day for *every* match in the world (~300, ~200 KB). Asked with
  `timezone=America/Argentina/Buenos_Aires`, so FotMob's day is our day and a
  20:00 match isn't filed under tomorrow by its UTC time.

  Not Sofascore: its equivalent endpoint is the same request count but it is
  the provider that blocks our IP, and the calendar is the page most likely to
  be opened by people who aren't logged in. Every reader shares one cached copy
  per day whatever their filters, so traffic to FotMob doesn't grow with visits.

  Days are cached with a TTL that follows how fast they change (see
  `ttl_for/2`), and the last good copy of each day is kept for a few days so a
  FotMob outage shows slightly old scores rather than an empty week.
  """

  require Logger
  import Ecto.Query, warn: false

  alias Colloq.Repo
  alias Colloq.Forum.Topic

  @tz "America/Argentina/Buenos_Aires"
  @endpoint "https://www.fotmob.com/api/data/matches"
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  @stale_ttl :timer.hours(72)

  # FotMob ids. Teams are matched by id, not name: "Racing Club" is also
  # Racing de Montevideo's name in some feeds.
  @racing 10_080
  @argentina 6706
  @liga_profesional 112

  # `default: true` filters start switched on; the rest are opt-in, so the
  # grid isn't buried under European football until someone asks for it.
  # League ids verified against FotMob's /api/data/leagues.
  @filters [
    %{key: "racing", group: :teams, match: {:team, @racing}, default: true},
    %{key: "argentina", group: :teams, match: {:team, @argentina}, default: true},
    %{key: "liga", group: :competitions, match: {:league, @liga_profesional}, default: true},
    %{key: "primera_nacional", group: :competitions, match: {:league, 8965}, default: false},
    %{key: "copa_argentina", group: :competitions, match: {:league, 9305}, default: false},
    %{key: "libertadores", group: :competitions, match: {:league, 45}, default: false},
    %{key: "sudamericana", group: :competitions, match: {:league, 299}, default: false},
    %{key: "champions", group: :competitions, match: {:league, 42}, default: false},
    %{key: "premier", group: :competitions, match: {:league, 47}, default: false},
    %{key: "laliga", group: :competitions, match: {:league, 87}, default: false},
    %{key: "serie_a", group: :competitions, match: {:league, 55}, default: false},
    %{key: "bundesliga", group: :competitions, match: {:league, 54}, default: false}
  ]

  @doc "Filter definitions in display order: `%{key, group, match, default}`."
  def filters, do: @filters

  @doc "Keys of the filters a first visit starts with."
  def default_filter_keys, do: for(f <- @filters, f.default, do: f.key)

  @doc "Ids of the teams the forum follows, for highlighting them on cards."
  def followed_team_ids, do: [@racing, @argentina]

  @doc "The Argentine calendar date right now."
  def today, do: DateTime.now!(@tz) |> DateTime.to_date()

  @doc "Monday of the week containing `date`."
  def week_start(%Date{} = date), do: Date.add(date, 1 - Date.day_of_week(date))

  @doc """
  The seven days starting at `monday`, as `{date, matches}` with the matches of
  *every* competition, sorted by kickoff. Filtering is the caller's job
  (`filter/2`), so one fetch serves every combination of toggles.

  Returns `%{days: [...], stale?: bool, failed?: bool}`: `stale?` when some day
  came from the saved copy, `failed?` when some day has no data at all.
  """
  def week(%Date{} = monday) do
    dates = Enum.map(0..6, &Date.add(monday, &1))

    # Two at a time, to be polite. The timeout is long because FotMob answers a
    # day nobody has asked about lately in 7–20 s (under 1 s once warm).
    results =
      dates
      |> Task.async_stream(&day/1, max_concurrency: 2, timeout: 35_000, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)

    days =
      Enum.zip_with(dates, results, fn
        date, {status, matches} when status in [:ok, :stale] -> {date, matches}
        date, _ -> {date, []}
      end)

    %{
      days: days,
      stale?: Enum.any?(results, &match?({:stale, _}, &1)),
      failed?: Enum.any?(results, &match?({:error, _}, &1))
    }
  end

  @doc "Matches passing any of the enabled filter keys."
  def filter(matches, enabled_keys) do
    active = Enum.filter(@filters, &(&1.key in enabled_keys))
    Enum.filter(matches, fn m -> Enum.any?(active, &matches_filter?(m, &1)) end)
  end

  @doc "How many of `matches` each filter would show, as `%{key => count}`."
  def counts(matches) do
    Map.new(@filters, fn f -> {f.key, Enum.count(matches, &matches_filter?(&1, f))} end)
  end

  @doc "The filter key a match is shown for first (drives its card colour)."
  def filter_key(match) do
    Enum.find_value(@filters, fn f -> if matches_filter?(match, f), do: f.key end)
  end

  defp matches_filter?(m, %{match: {:team, id}}), do: m.home_id == id or m.away_id == id
  defp matches_filter?(m, %{match: {:league, id}}), do: m.league_id == id

  # --- Fetching ----------------------------------------------------------------

  # `{:ok, matches}`, `{:stale, matches}` (saved copy) or `{:error, reason}`.
  defp day(date) do
    key = "calendar:fotmob:#{Date.to_iso8601(date)}"

    result =
      Cachex.fetch(:forum_cache, key, fn _ ->
        case fetch_day(date) do
          {:ok, matches} ->
            Cachex.put(:forum_cache, stale_key(date), matches, ttl: @stale_ttl)
            {:commit, matches, ttl: ttl_for(date, matches)}

          error ->
            {:ignore, error}
        end
      end)

    # A fresh commit comes back with its options attached: `{:commit, value, opts}`.
    case result do
      {status, matches} when status in [:ok, :commit] and is_list(matches) ->
        {:ok, matches}

      {:commit, matches, _opts} when is_list(matches) ->
        {:ok, matches}

      {_, error} ->
        case Cachex.get(:forum_cache, stale_key(date)) do
          {:ok, matches} when is_list(matches) -> {:stale, matches}
          _ -> if match?({:error, _}, error), do: error, else: {:error, error}
        end
    end
  end

  defp stale_key(date), do: "calendar:fotmob:stale:#{Date.to_iso8601(date)}"

  # A day being played changes by the minute; a finished one never does.
  @doc false
  def ttl_for(date, matches) do
    today = today()

    cond do
      Enum.any?(matches, &(&1.status in [:live, :halftime])) -> :timer.minutes(1)
      Date.compare(date, today) == :eq -> :timer.minutes(3)
      Date.compare(date, today) == :lt -> :timer.hours(6)
      true -> :timer.hours(1)
    end
  end

  defp fetch_day(date) do
    url = "#{@endpoint}?date=#{Calendar.strftime(date, "%Y%m%d")}&timezone=#{@tz}"

    case Req.get(url,
           headers: %{"user-agent" => @user_agent, "accept" => "application/json"},
           receive_timeout: 30_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"leagues" => leagues}}} when is_list(leagues) ->
        {:ok, parse(leagues)}

      {:ok, %{status: status}} ->
        Logger.warning("[Calendar] FotMob #{date} -> HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[Calendar] FotMob #{date} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def parse(leagues) do
    leagues
    |> Enum.flat_map(fn league ->
      league_id = league["primaryId"] || league["id"]
      # Group stages come as "UEFA Nations League A Grp. 4"; the parent name is
      # the competition people know.
      league_name = league["parentLeagueName"] || league["name"]

      league["matches"]
      |> List.wrap()
      |> Enum.map(&parse_match(&1, league_id, league_name))
    end)
    |> Enum.reject(&is_nil(&1.kickoff))
    |> Enum.sort_by(&{DateTime.to_unix(&1.kickoff), &1.league_name})
  end

  defp parse_match(m, league_id, league_name) do
    status = m["status"] || %{}
    {state, minute} = state(status)
    started? = state in [:live, :halftime, :finished]

    %{
      id: m["id"],
      league_id: league_id,
      league_name: league_name,
      kickoff: parse_time(status["utcTime"]),
      home: get_in(m, ["home", "name"]),
      away: get_in(m, ["away", "name"]),
      home_id: get_in(m, ["home", "id"]),
      away_id: get_in(m, ["away", "id"]),
      home_score: if(started?, do: get_in(m, ["home", "score"])),
      away_score: if(started?, do: get_in(m, ["away", "score"])),
      status: state,
      minute: minute
    }
  end

  defp state(status) do
    reason = get_in(status, ["reason", "short"])
    long_key = get_in(status, ["reason", "longKey"]) || ""

    cond do
      status["cancelled"] == true and String.contains?(long_key, "postponed") -> {:postponed, nil}
      status["cancelled"] == true -> {:cancelled, nil}
      status["finished"] == true -> {:finished, nil}
      status["started"] == true and reason == "HT" -> {:halftime, nil}
      status["started"] == true -> {:live, live_minute(status)}
      true -> {:prematch, nil}
    end
  end

  # "67’" → "67'". Missing during the first seconds of a half.
  defp live_minute(status) do
    case get_in(status, ["liveTime", "short"]) do
      short when is_binary(short) -> String.replace(short, "’", "'")
      _ -> nil
    end
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  @doc "Kickoff as Argentine `HH:MM`."
  def local_time(%DateTime{} = dt), do: dt |> DateTime.shift_zone!(@tz) |> Calendar.strftime("%H:%M")

  # --- Match threads -------------------------------------------------------------

  @doc """
  The forum's match thread for each match that has one, as
  `%{match_id => topic}`.

  Calendar matches are FotMob's and match threads store a Sofascore id, so
  there is no id to join on. A thread belongs to a match when it was opened in
  the days before kickoff and its title names the match: both teams, or one of
  them when it was opened within a day of kickoff (titles nickname rivals —
  "ribergay" — but a Racing thread opened that morning is about that match).
  """
  def match_threads([]), do: %{}

  def match_threads(matches) do
    {from, to} =
      matches
      |> Enum.map(& &1.kickoff)
      |> Enum.min_max_by(&DateTime.to_unix/1)

    threads =
      Topic
      |> where([t], t.is_match_thread == true and is_nil(t.deleted_at))
      |> where([t], t.inserted_at >= ^DateTime.add(from, -4, :day))
      |> where([t], t.inserted_at <= ^DateTime.add(to, 3, :hour))
      |> select([t], %{id: t.id, slug: t.slug, title: t.title, inserted_at: t.inserted_at})
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :norm, normalize(&1.title)))

    matches
    |> Enum.flat_map(fn m ->
      case Enum.find(threads, &thread_for_match?(&1, m)) do
        nil -> []
        thread -> [{m.id, thread}]
      end
    end)
    |> Map.new()
  end

  defp thread_for_match?(thread, m) do
    opened = DateTime.diff(m.kickoff, thread.inserted_at, :hour)
    home? = names_team?(thread.norm, m.home)
    away? = names_team?(thread.norm, m.away)

    opened >= -3 and opened <= 96 and
      ((home? and away?) or ((home? or away?) and opened <= 24))
  end

  # Words too common in club names to identify one ("Club Atlético …").
  @generic ~w(club atletico athletic deportivo sociedad sporting juniors plate united city real fc cf ca cd sc de del la los las el and the)

  defp names_team?(norm_title, name) when is_binary(name) do
    words = String.split(normalize(name), ~r/[^a-z0-9]+/, trim: true)

    words
    |> Enum.reject(&(&1 in @generic or String.length(&1) < 3))
    |> Enum.any?(&String.contains?(norm_title, &1))
  end

  defp names_team?(_, _), do: false

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end
end
