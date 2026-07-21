defmodule Colloq.Sofascore do
  @moduledoc """
  Sofascore player context.

  Manages the local database of Sofascore player IDs for querying
  stats, lineups, and other match data.

  Supports multiple teams from the Argentine league and other competitions.
  Squads are fetched dynamically from the Sofascore API
  (/team/{id}/players endpoint) and cached locally in the database.
  """

  require Logger

  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Sofascore.SofascorePlayer

  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  defp api_base, do: Application.get_env(:colloq, :sofascore_api_url, "https://www.sofascore.com/api/v1")

  # Maps Sofascore API position codes to Spanish labels
  @position_map %{
    "G" => "Arquero",
    "D" => "Defensor",
    "M" => "Mediocampista",
    "F" => "Delantero"
  }

  # ===========================================================================
  # Known teams registry
  # ===========================================================================

  # Sofascore team IDs, verified via /search/all (the previous values were
  # wrong — e.g. 174 is Farsley Celtic, not Racing).
  # `colors` are the club's kit colors (primary body, secondary trim/stroke),
  # used to paint the lineup jerseys.
  @teams %{
    racing: %{id: 3215, name: "Racing Club", short: "RAC", colors: %{primary: "#8FC7E8", secondary: "#2E6E9E"}},
    river: %{id: 3211, name: "River Plate", short: "RIV", colors: %{primary: "#FFFFFF", secondary: "#D3111F"}},
    boca: %{id: 3202, name: "Boca Juniors", short: "BOC", colors: %{primary: "#0A2E6E", secondary: "#F2C300"}},
    independiente: %{id: 3209, name: "Independiente", short: "IND", colors: %{primary: "#D8161B", secondary: "#7A0C10"}},
    san_lorenzo: %{id: 3201, name: "San Lorenzo", short: "SLO", colors: %{primary: "#12294F", secondary: "#B01B2E"}},
    estudiantes: %{id: 3206, name: "Estudiantes", short: "EST", colors: %{primary: "#FFFFFF", secondary: "#D3111F"}},
    lanus: %{id: 3218, name: "Lanús", short: "LAN", colors: %{primary: "#6E1423", secondary: "#3E0B14"}},
    argentinos: %{id: 3216, name: "Argentinos Juniors", short: "ARJ", colors: %{primary: "#D8161B", secondary: "#B0B0B0"}},
    talleres: %{id: 3210, name: "Talleres", short: "TAL", colors: %{primary: "#1F55A5", secondary: "#FFFFFF"}},
    rosario_central: %{id: 3217, name: "Rosario Central", short: "ROC", colors: %{primary: "#0B3E9B", secondary: "#F2C300"}},
    newells: %{id: 3212, name: "Newell's Old Boys", short: "NOB", colors: %{primary: "#D8161B", secondary: "#111111"}},
    velez: %{id: 3208, name: "Vélez Sarsfield", short: "VEL", colors: %{primary: "#FFFFFF", secondary: "#123A8B"}}
  }

  # Fallback kit for teams not in the registry (plain white with a soft trim).
  @default_colors %{primary: "#E8EEF7", secondary: "#9DB4D0"}

  @doc """
  Returns the known teams map with their Sofascore IDs.
  """
  def teams, do: @teams

  @doc """
  Kit colors for a team id — `%{primary, secondary}`. Falls back to a neutral
  white kit for unknown teams.
  """
  def team_colors(team_id) do
    case team_key_by_id(team_id) do
      nil -> @default_colors
      key -> Map.get(team_info(key), :colors, @default_colors)
    end
  end

  @doc """
  Returns team info by atom key (e.g. :racing, :river).
  """
  def team_info(key) when is_atom(key), do: Map.get(@teams, key)

  @doc """
  Returns the team atom key from a Sofascore team_id.
  """
  def team_key_by_id(team_id) do
    Enum.find_value(@teams, fn {key, %{id: id}} ->
      if id == team_id, do: key
    end)
  end

  # ===========================================================================
  # Queries
  # ===========================================================================

  @doc """
  Gets a player by their Sofascore ID. Raises if not found.
  """
  def get_player!(sofascore_id) do
    Repo.get_by!(SofascorePlayer, sofascore_id: sofascore_id)
  end

  @doc """
  Gets a player by their Sofascore ID. Returns nil if not found.
  """
  def get_player(sofascore_id) do
    Repo.get_by(SofascorePlayer, sofascore_id: sofascore_id)
  end

  @doc """
  Searches players by name (ILIKE search).
  """
  def search(query) when is_binary(query) and query != "" do
    search_term = "%#{query}%"

    SofascorePlayer
    |> where([p], ilike(p.name, ^search_term))
    |> order_by(:name)
    |> limit(20)
    |> Repo.all()
  end

  def search(_), do: []

  @doc """
  Lists all players for a team by Sofascore team_id.
  """
  def list_by_team(team_id) when is_integer(team_id) do
    SofascorePlayer
    |> where([p], p.team_id == ^team_id)
    |> order_by([p], [p.position, p.name])
    |> Repo.all()
  end

  @doc """
  Lists all players for a team by atom key.
  """
  def list_by_team(team_key) when is_atom(team_key) do
    case team_info(team_key) do
      %{id: id} -> list_by_team(id)
      nil -> []
    end
  end

  @doc """
  Lists players for a team filtered by position.

  Positions: "Arquero", "Defensor", "Mediocampista", "Delantero"
  """
  def list_by_team_and_position(team_id, position)
      when is_integer(team_id) and is_binary(position) do
    SofascorePlayer
    |> where([p], p.team_id == ^team_id and p.position == ^position)
    |> order_by(:name)
    |> Repo.all()
  end

  def list_by_team_and_position(team_key, position) when is_atom(team_key) do
    case team_info(team_key) do
      %{id: id} -> list_by_team_and_position(id, position)
      nil -> []
    end
  end

  @doc """
  Counts how many players are registered for a team.
  """
  def count_by_team(team_id) when is_integer(team_id) do
    SofascorePlayer
    |> where([p], p.team_id == ^team_id)
    |> Repo.aggregate(:count, :id)
  end

  def count_by_team(team_key) when is_atom(team_key) do
    case team_info(team_key) do
      %{id: id} -> count_by_team(id)
      nil -> 0
    end
  end

  @doc """
  Lists all teams that have registered players.
  """
  def teams_with_players do
    SofascorePlayer
    |> select([p], p.team_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.map(fn team_id ->
      case team_key_by_id(team_id) do
        nil -> %{id: team_id, name: "Team #{team_id}", key: nil}
        key -> %{id: team_id, name: @teams[key].name, key: key}
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  # ===========================================================================
  # Fetch from Sofascore API
  # ===========================================================================

  @doc """
  Fetches a team's squad from the Sofascore API and upserts into the local DB.
  Updates names and positions if the player already exists.

  Accepts a team atom key (:racing, :river, etc.) or a numeric team_id.

  Returns {:ok, count} or {:error, reason}.
  """
  def fetch_and_seed_squad(team_key) when is_atom(team_key) do
    %{id: id} = team_info(team_key)
    fetch_and_seed_squad(id)
  end

  def fetch_and_seed_squad(team_id) when is_integer(team_id) do
    case fetch_team_players(team_id) do
      {:ok, players} ->
        seed_squad(team_id, players)

      {:error, :not_found} ->
        Logger.warning("[Sofascore] Team #{team_id} not found in API")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[Sofascore] Error fetching squad team #{team_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches squads for all known teams and seeds them into the local DB.

  Returns {:ok, results} where results is a list of {team_key, result}.
  Teams that already have players in the DB are skipped unless force: true.
  """
  def fetch_and_seed_all(opts \\ []) do
    force = Keyword.get(opts, :force, false)

    results =
      @teams
      |> Enum.map(fn {key, _info} ->
        if not force and count_by_team(key) > 0 do
          {key, :skipped}
        else
          # Rate limiting: random delay between requests
          Process.sleep(:rand.uniform(1000) + 500)
          {key, fetch_and_seed_squad(key)}
        end
      end)

    {:ok, results}
  end

  @doc """
  Calls the Sofascore /team/{id}/players endpoint and parses the response
  into a list of maps compatible with seed_squad/2.

  Returns {:ok, players} or {:error, reason}.
  """
  def fetch_team_players(team_id) when is_integer(team_id) do
    case Req.get("#{api_base()}/team/#{team_id}/players",
           headers: %{
             "user-agent" => @user_agent,
             "accept" => "application/json"
           },
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"players" => raw_players}}} ->
        players =
          raw_players
          |> Enum.map(&parse_api_player/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, players}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parses a player from the Sofascore API format.
  # Response shape: %{"player" => %{...}}.
  defp parse_api_player(%{"player" => player_data}) do
    %{
      sofascore_id: to_string(player_data["id"]),
      name: player_data["name"],
      position: translate_position(player_data["position"]),
      photo_url: player_data["photoUrl"]
    }
  end

  defp parse_api_player(_), do: nil

  defp translate_position(code) when is_binary(code), do: Map.get(@position_map, code, code)
  defp translate_position(_), do: nil

  # ===========================================================================
  # Seeding (from already-fetched data)
  # ===========================================================================

  @doc """
  Inserts or updates a team's squad from a list of player maps.

  Accepts a team atom key (:racing, :river, etc.) or a numeric team_id,
  along with a list of maps containing: sofascore_id, name, position, photo_url (optional).
  """
  def seed_squad(team_key, players) when is_atom(team_key) and is_list(players) do
    %{id: team_id} = team_info(team_key)
    seed_squad(team_id, players)
  end

  def seed_squad(team_id, players) when is_integer(team_id) and is_list(players) do
    players = Enum.map(players, &Map.put(&1, :team_id, team_id))

    Repo.transaction(fn ->
      Enum.each(players, fn attrs ->
        %SofascorePlayer{}
        |> SofascorePlayer.changeset(attrs)
        |> Repo.insert!(
          on_conflict: [
            set: [
              name: attrs[:name] || attrs["name"],
              position: attrs[:position] || attrs["position"],
              photo_url: attrs[:photo_url] || attrs["photo_url"],
              team_id: team_id
            ]
          ],
          conflict_target: :sofascore_id
        )
      end)
    end)

    {:ok, length(players)}
  end

  # ===========================================================================
  # Job scheduling — thin wrappers over Colloq.Workers.SofascoreWorker so app
  # code, IEx and the admin panel enqueue jobs without hand-building them.
  # ===========================================================================

  alias Colloq.Workers.SofascoreWorker

  @doc "Enqueue a fixtures refresh for every team that has players."
  def refresh_fixtures, do: enqueue(%{"action" => "fetch_fixtures"})

  @doc "Enqueue a fixtures refresh for one team (Sofascore team_id)."
  def refresh_fixtures(team_id) when is_integer(team_id),
    do: enqueue(%{"action" => "fetch_fixtures", "team_id" => team_id})

  @doc "Enqueue a squad refresh for every known team."
  def refresh_squads, do: enqueue(%{"action" => "fetch_squad"})

  @doc "Enqueue a squad refresh for one team (Sofascore team_id)."
  def refresh_squad(team_id) when is_integer(team_id),
    do: enqueue(%{"action" => "fetch_squad", "team_id" => team_id})

  @doc "Enqueue a standings refresh for a season."
  def refresh_standings(season_id) when is_integer(season_id),
    do: enqueue(%{"action" => "fetch_standings", "season_id" => season_id})

  @doc "Enqueue a lineups refresh for a specific match/event."
  def refresh_lineups(event_id) when is_integer(event_id),
    do: enqueue(%{"action" => "fetch_lineups", "event_id" => event_id})

  @doc "Enqueue a player-stats refresh."
  def refresh_stats(player_id, season_id, status)
      when is_integer(player_id) and is_integer(season_id) and is_binary(status),
      do:
        enqueue(%{
          "action" => "fetch_stats",
          "player_id" => player_id,
          "season_id" => season_id,
          "status" => status
        })

  defp enqueue(args) do
    args
    |> SofascoreWorker.new()
    |> Oban.insert()
  end

  @doc """
  The current Liga season id, read from the `sofascore_season_id` site setting.
  Returns `nil` when unset (standings/stats need it). Set it once per season in
  Admin ▸ Settings.
  """
  def current_season_id do
    case Colloq.SiteSettings.get("sofascore_season_id") do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc "Sofascore team_id for Racing Club."
  def racing_team_id, do: @teams.racing.id

  @doc """
  Squad for a team, DB-first: returns the locally stored players, and if none
  exist yet, fetches + seeds them from the API once, then returns them. This is
  what the `/sofascore plantel` command uses so it self-heals on a cold DB.
  """
  def list_or_fetch_squad(team_id) when is_integer(team_id) do
    case list_by_team(team_id) do
      [] ->
        case fetch_and_seed_squad(team_id) do
          {:ok, _count} -> list_by_team(team_id)
          _ -> []
        end

      players ->
        players
    end
  end

  # ===========================================================================
  # On-demand reads (cache-first, fetch on miss) — used by the /sofascore
  # in-topic command so it can answer immediately even on a cold cache.
  # ===========================================================================

  @doc "Next upcoming fixture for a team. `{:ok, event}` or `{:error, reason}`."
  def next_fixture(team_id) when is_integer(team_id) do
    key = "sofascore:fixtures:#{team_id}"

    events =
      case Cachex.get(:forum_cache, key) do
        {:ok, evs} when is_list(evs) and evs != [] ->
          evs

        _ ->
          case api_get("/team/#{team_id}/events/next/0") do
            {:ok, %{"events" => evs}} when is_list(evs) ->
              Cachex.put(:forum_cache, key, evs, ttl: :timer.hours(12))
              evs

            _ ->
              []
          end
      end

    case events do
      [event | _] -> {:ok, event}
      _ -> {:error, :no_fixtures}
    end
  end

  @doc """
  Upcoming fixtures for a team, ready for a picker: `%{id, label, starts_at}`.

  Backs the "match thread" control in the topic editor, so setting one up is
  choosing a real fixture from a list rather than pasting an event id — the two
  silent failure modes were a wrong id (the bot covers another club's game) and
  a non-string id (the banner just never renders).

  Shares `next_fixture/1`'s 12h cache, so opening the editor costs no request.
  """
  def upcoming_fixtures(team_id, limit \\ 8) when is_integer(team_id) do
    key = "sofascore:fixtures:#{team_id}"

    events =
      case Cachex.get(:forum_cache, key) do
        {:ok, evs} when is_list(evs) and evs != [] ->
          evs

        _ ->
          case api_get("/team/#{team_id}/events/next/0") do
            {:ok, %{"events" => evs}} when is_list(evs) ->
              Cachex.put(:forum_cache, key, evs, ttl: :timer.hours(12))
              evs

            _ ->
              []
          end
      end

    events
    |> Enum.take(limit)
    |> Enum.map(fn e ->
      %{
        id: to_string(e["id"]),
        label: fixture_label(e),
        starts_at: e["startTimestamp"]
      }
    end)
  end

  defp fixture_label(event) do
    home = get_in(event, ["homeTeam", "name"]) || "?"
    away = get_in(event, ["awayTeam", "name"]) || "?"
    comp = get_in(event, ["tournament", "name"])

    when_ =
      case event["startTimestamp"] do
        nil ->
          ""

        ts ->
          ts
          |> DateTime.from_unix!(:second)
          |> DateTime.shift_zone!("America/Argentina/Buenos_Aires")
          |> Calendar.strftime(" — %d/%m %H:%M")
      end

    "#{home} vs #{away}#{when_}#{if comp, do: " (#{comp})", else: ""}"
  rescue
    # A picker that raises because the timezone table is still loading would
    # take the whole topic editor down with it.
    _ -> "#{get_in(event, ["homeTeam", "name"])} vs #{get_in(event, ["awayTeam", "name"])}"
  end

  @doc """
  The most relevant match for a team *right now*: a live one if it's playing,
  otherwise the next upcoming fixture, otherwise the most recent finished one.
  Returns `{:ok, event}` or `{:error, :no_fixtures}`.

  Unlike `next_fixture/1`, this looks at both recent and upcoming events (a live
  match sits in the team's "last" list once it kicks off) and uses a short 30s
  cache so a live clock stays current without hammering the API.
  """
  def relevant_match(team_id) when is_integer(team_id) do
    key = "sofascore:relevant:#{team_id}"

    events =
      case Cachex.get(:forum_cache, key) do
        {:ok, evs} when is_list(evs) and evs != [] ->
          evs

        _ ->
          evs = fetch_last_and_next(team_id)
          if evs != [], do: Cachex.put(:forum_cache, key, evs, ttl: :timer.seconds(30))
          evs
      end

    case pick_relevant(events) do
      nil -> {:error, :no_fixtures}
      event -> {:ok, event}
    end
  end

  defp fetch_last_and_next(team_id) do
    last = fetch_events("/team/#{team_id}/events/last/0")
    next = fetch_events("/team/#{team_id}/events/next/0")
    (last ++ next) |> Enum.uniq_by(& &1["id"])
  end

  defp fetch_events(path) do
    case api_get(path) do
      {:ok, %{"events" => evs}} when is_list(evs) -> evs
      _ -> []
    end
  end

  # Prefer a live match; else the soonest not-yet-past upcoming; else the most
  # recent finished. `status.type` is Sofascore's stable state field.
  defp pick_relevant(events) do
    case Enum.find(events, &(get_in(&1, ["status", "type"]) == "inprogress")) do
      %{} = live ->
        live

      nil ->
        now = System.system_time(:second)

        upcoming =
          events
          |> Enum.filter(&(get_in(&1, ["status", "type"]) == "notstarted"))
          |> Enum.filter(&is_integer(&1["startTimestamp"]))
          # drop anything more than 3h past (stale "upcoming" that never updated)
          |> Enum.filter(&(&1["startTimestamp"] >= now - 3 * 3600))
          |> Enum.sort_by(& &1["startTimestamp"])
          |> List.first()

        upcoming || most_recent_finished(events)
    end
  end

  defp most_recent_finished(events) do
    events
    |> Enum.filter(&(get_in(&1, ["status", "type"]) == "finished"))
    |> Enum.filter(&is_integer(&1["startTimestamp"]))
    |> Enum.sort_by(& &1["startTimestamp"], :desc)
    |> List.first()
  end

  @doc """
  The team's most recent *finished* match — the "partido anterior". Unlike
  `relevant_match/1` (which prefers an upcoming fixture), this always returns the
  last result. `{:ok, event}` or `{:error, :no_fixtures}`.

  A finished result never changes, so it's cached 10 minutes.
  """
  def last_finished_match(team_id) when is_integer(team_id) do
    key = "sofascore:last:#{team_id}"

    events =
      case Cachex.get(:forum_cache, key) do
        {:ok, evs} when is_list(evs) and evs != [] ->
          evs

        _ ->
          evs = fetch_events("/team/#{team_id}/events/last/0")
          if evs != [], do: Cachex.put(:forum_cache, key, evs, ttl: :timer.minutes(10))
          evs
      end

    case most_recent_finished(events) do
      nil -> {:error, :no_fixtures}
      event -> {:ok, event}
    end
  end

  @doc """
  Goal incidents for an event, chronological. Each: `%{name, minute, home?, kind}`
  where `kind` is `"penalty"`, `"ownGoal"` or `"regular"`. Empty list if the match
  hasn't started or the fetch fails.

  30s cache so a live match's goals appear promptly without re-fetching per view.
  """
  def goals(event_id) when is_integer(event_id) do
    key = "sofascore:incidents:#{event_id}"

    incidents =
      case Cachex.get(:forum_cache, key) do
        {:ok, list} when is_list(list) ->
          list

        _ ->
          list =
            case api_get("/event/#{event_id}/incidents") do
              {:ok, %{"incidents" => inc}} when is_list(inc) -> inc
              _ -> []
            end

          Cachex.put(:forum_cache, key, list, ttl: :timer.seconds(30))
          list
      end

    incidents
    |> Enum.filter(&(&1["incidentType"] == "goal"))
    |> Enum.map(fn g ->
      %{
        name: get_in(g, ["player", "name"]) || "?",
        minute: g["time"],
        home?: g["isHome"] == true,
        kind: g["incidentClass"] || "regular"
      }
    end)
    |> Enum.sort_by(&(&1.minute || 0))
  end

  @doc """
  The year-long cumulative "tabla anual" — Sofascore models it as a separate
  season under the same tournament, so this reuses `standings/1` with the
  configured annual season id (site setting `sofascore_annual_season_id`).
  `{:ok, data}`, `{:error, :no_annual}` or `{:error, reason}`.
  """
  def annual_standings do
    case Colloq.SiteSettings.get("sofascore_annual_season_id") do
      season_id when is_integer(season_id) -> standings(season_id)
      _ -> {:error, :no_annual}
    end
  end

  @doc "League standings for a season. `{:ok, data}` or `{:error, reason}`."
  def standings(season_id) when is_integer(season_id) do
    key = "sofascore:standings:#{season_id}"

    case Cachex.get(:forum_cache, key) do
      {:ok, data} when not is_nil(data) ->
        {:ok, data}

      _ ->
        case api_get("/unique-tournament/155/season/#{season_id}/standings/total") do
          {:ok, data} ->
            Cachex.put(:forum_cache, key, data, ttl: :timer.hours(12))
            {:ok, data}

          err ->
            err
        end
    end
  end

  @doc "Overall season statistics for a player. `{:ok, data}` or `{:error, _}`."
  def player_stats(player_id, season_id) when is_integer(player_id) and is_integer(season_id) do
    player_stats(player_id, 155, season_id)
  end

  @doc """
  Overall season statistics for a player in a specific tournament and season.

  `data` includes the `statistics` object and the `team` the player was at.
  Cached 6h. `{:ok, data}` or `{:error, _}`.
  """
  def player_stats(player_id, tournament_id, season_id)
      when is_integer(player_id) and is_integer(tournament_id) and is_integer(season_id) do
    key = "sofascore:stats:#{player_id}:#{tournament_id}:#{season_id}"

    case Cachex.get(:forum_cache, key) do
      {:ok, data} when not is_nil(data) ->
        {:ok, data}

      _ ->
        path =
          "/player/#{player_id}/unique-tournament/#{tournament_id}/season/#{season_id}/statistics/overall"

        case api_get(path) do
          {:ok, data} ->
            Cachex.put(:forum_cache, key, data, ttl: :timer.hours(6))
            {:ok, data}

          err ->
            err
        end
    end
  end

  @doc """
  Tournaments and seasons a player has statistics for — powers the year/team
  selectors on the player card. Cached 12h.

  Returns `{:ok, [%{tournament_id, tournament_name, seasons: [%{id, year}]}]}`,
  most-recent tournaments first (as Sofascore orders them).
  """
  def player_seasons(player_id) when is_integer(player_id) do
    key = "sofascore:seasons:#{player_id}"

    case Cachex.get(:forum_cache, key) do
      {:ok, data} when is_list(data) and data != [] ->
        {:ok, data}

      _ ->
        case api_get("/player/#{player_id}/statistics/seasons") do
          {:ok, body} ->
            parsed = parse_player_seasons(body)
            Cachex.put(:forum_cache, key, parsed, ttl: :timer.hours(12))
            {:ok, parsed}

          err ->
            err
        end
    end
  end

  # Sofascore shape: %{"uniqueTournamentSeasons" => [%{"uniqueTournament" =>
  # %{id, name}, "seasons" => [%{id, year, name}]}]}. Tolerant of missing keys.
  defp parse_player_seasons(%{"uniqueTournamentSeasons" => list}) when is_list(list) do
    list
    |> Enum.map(fn entry ->
      ut = entry["uniqueTournament"] || %{}

      seasons =
        (entry["seasons"] || [])
        |> Enum.map(fn s -> %{id: s["id"], year: s["year"] || s["name"]} end)
        |> Enum.reject(&is_nil(&1.id))

      %{tournament_id: ut["id"], tournament_name: ut["name"], seasons: seasons}
    end)
    |> Enum.reject(&(is_nil(&1.tournament_id) or &1.seasons == []))
  end

  defp parse_player_seasons(_), do: []

  @doc """
  Assembles the payload the player-card SVG needs: resolves a tournament/season
  (defaulting to the most recent the player has data for), fetches that season's
  stats + team, and returns everything the renderer and the selectors need.

  `opts`: `:tournament_id`, `:season_id` (both optional — omitted picks the
  latest). Returns `{:ok, card}` or `{:error, :unavailable}`.
  """
  def player_card(%SofascorePlayer{} = player, opts \\ []) do
    with {id, _} <- Integer.parse(to_string(player.sofascore_id)),
         {:ok, seasons} when seasons != [] <- player_seasons(id),
         {tid, sid, label} <- resolve_season(id, seasons, opts) do
      data =
        case player_stats(id, tid, sid) do
          {:ok, d} -> d
          _ -> %{}
        end

      {:ok,
       %{
         name: player.name,
         id: id,
         position: player.position,
         team_name: get_in(data, ["team", "name"]),
         season_label: label,
         stats: Map.get(data, "statistics", %{}),
         seasons: seasons,
         tournament_id: tid,
         season_id: sid
       }}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc """
  Full career table: every season the player has, aggregated by year across all
  competitions (MP/MIN/GLS/AST), with the per-competition breakdown kept for
  expandable rows. Sorted most-recent first. Cached per player (12h) since it
  fans out to one stats call per (tournament, season).

  Returns `{:ok, %{name, id, position, rows}}` where each row is
  `%{year, end_year, mp, min, gls, ast, teams, competitions}`.
  """
  def player_career(%SofascorePlayer{} = player) do
    with {id, _} <- Integer.parse(to_string(player.sofascore_id)),
         {:ok, seasons} when seasons != [] <- player_seasons(id) do
      key = "sofascore:career:#{id}"

      rows =
        case Cachex.get(:forum_cache, key) do
          {:ok, r} when is_list(r) and r != [] ->
            r

          _ ->
            r = build_career(id, seasons)
            Cachex.put(:forum_cache, key, r, ttl: :timer.hours(12))
            r
        end

      {:ok, %{name: player.name, id: id, position: player.position, rows: rows}}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp build_career(id, seasons) do
    seasons
    |> Enum.flat_map(fn %{tournament_id: tid, tournament_name: tname, seasons: ss} ->
      Enum.map(ss, fn %{id: sid, year: year} -> {tid, tname, sid, to_string(year)} end)
    end)
    |> Task.async_stream(
      fn {tid, tname, sid, year} -> competition_stats(id, tid, tname, sid, year) end,
      max_concurrency: 6,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, c} when is_map(c) -> [c]
      _ -> []
    end)
    |> Enum.group_by(& &1.year)
    |> Enum.map(fn {year, comps} ->
      %{
        year: year,
        end_year: season_end_year(year),
        mp: sum(comps, :mp),
        min: sum(comps, :min),
        gls: sum(comps, :gls),
        ast: sum(comps, :ast),
        teams: comps |> Enum.map(&{&1.team_id, &1.team_name}) |> Enum.uniq() |> Enum.reject(&(elem(&1, 0) == nil)),
        competitions: Enum.sort_by(comps, &(-&1.mp))
      }
    end)
    |> Enum.sort_by(& &1.end_year, :desc)
  end

  defp competition_stats(id, tid, tname, sid, year) do
    case player_stats(id, tid, sid) do
      {:ok, d} ->
        s = Map.get(d, "statistics", %{})

        %{
          tournament_id: tid,
          tournament_name: tname,
          year: year,
          team_id: get_in(d, ["team", "id"]),
          team_name: get_in(d, ["team", "name"]),
          mp: int(s["appearances"] || s["matchesPlayed"]),
          min: int(s["minutesPlayed"]),
          gls: int(s["goals"]),
          ast: int(s["assists"])
        }

      _ ->
        nil
    end
  end

  defp sum(list, key), do: Enum.reduce(list, 0, &(&2 + Map.get(&1, key, 0)))

  defp int(n) when is_number(n), do: round(n)
  defp int(_), do: 0

  # An explicit tournament+season wins. With none given, Sofascore lists
  # tournaments in an unhelpful order (national-team cups like the World Cup
  # come first), so we default to the player's *primary* competition — the one
  # with the most appearances in its latest season (usually their club league).
  defp resolve_season(id, seasons, opts) do
    cond do
      opts[:tournament_id] && opts[:season_id] ->
        resolve_explicit(seasons, opts) || default_season(id, seasons)

      opts[:year] ->
        year_season(id, seasons, opts[:year]) || default_season(id, seasons)

      true ->
        default_season(id, seasons)
    end
  end

  defp resolve_explicit(seasons, opts) do
    with %{seasons: ss, tournament_id: tid} <-
           Enum.find(seasons, &(&1.tournament_id == opts[:tournament_id])),
         %{id: sid, year: year} <- Enum.find(ss, &(&1.id == opts[:season_id])) do
      {tid, sid, to_string(year)}
    else
      _ -> nil
    end
  end

  # Default = the player's *current* primary competition: among each
  # tournament's latest season, pick the most recent by year, then (for that
  # year) the one with the most appearances — i.e. their main league now, not an
  # old season where they happened to play more games.
  defp default_season(id, seasons) do
    seasons
    |> Enum.take(10)
    |> Enum.flat_map(fn %{tournament_id: tid, seasons: ss} ->
      case List.first(ss) do
        %{id: sid, year: year} -> [candidate(id, tid, sid, year)]
        _ -> []
      end
    end)
    |> best_candidate()
    |> case do
      nil -> first_season(seasons)
      picked -> picked
    end
  end

  # Best season matching an explicit year (e.g. "2025"), across all
  # competitions — split-year labels like "24/25"/"25/26" count as matching
  # 2025. Among matches the primary competition (most appearances) wins.
  defp year_season(id, seasons, year) do
    seasons
    |> Enum.flat_map(fn %{tournament_id: tid, seasons: ss} ->
      ss
      |> Enum.filter(&year_matches?(&1.year, year))
      |> Enum.map(fn %{id: sid, year: y} -> candidate(id, tid, sid, y) end)
    end)
    |> best_by_appearances()
  end

  # {tid, sid, label, end_year, appearances} — the scoring tuple.
  defp candidate(id, tid, sid, year) do
    {tid, sid, to_string(year), season_end_year(year), appearances(id, tid, sid)}
  end

  # Most recent year wins; ties broken by appearances (the primary league).
  defp best_candidate([]), do: nil

  defp best_candidate(candidates) do
    {tid, sid, label, _yr, _apps} =
      Enum.max_by(candidates, fn {_, _, _, yr, apps} -> {yr, apps} end)

    {tid, sid, label}
  end

  defp best_by_appearances([]), do: nil

  defp best_by_appearances(candidates) do
    {tid, sid, label, _yr, _apps} =
      Enum.max_by(candidates, fn {_, _, _, _yr, apps} -> apps end)

    {tid, sid, label}
  end

  defp appearances(id, tid, sid) do
    case player_stats(id, tid, sid) do
      {:ok, d} ->
        s = Map.get(d, "statistics", %{})
        num(s["appearances"]) || num(s["matchesPlayed"]) || 0

      _ ->
        0
    end
  end

  # A season label matches a requested 4-digit year when it equals it, or when a
  # split-year label ("24/25", "25/26") starts or ends in that year.
  defp year_matches?(label, year) do
    y = to_string(year)
    label = to_string(label)

    case Regex.run(~r|^(\d{2,4})\s*/\s*(\d{2,4})$|, label) do
      [_, a, b] -> to_string(expand_year(a)) == y or to_string(expand_year(b)) == y
      _ -> label == y
    end
  end

  # Comparable "most recent" year for a label: end year of a split season, else
  # the plain 4-digit year. "24/25" → 2025, "2018" → 2018.
  defp season_end_year(label) do
    label = to_string(label)

    case Regex.run(~r|(\d{2,4})\s*/\s*(\d{2,4})$|, label) do
      [_, _, b] ->
        expand_year(b)

      _ ->
        case Regex.run(~r/(\d{4})/, label) do
          [_, y] -> String.to_integer(y)
          _ -> 0
        end
    end
  end

  # "25" → 2025, "2025" → 2025.
  defp expand_year(y) do
    n = String.to_integer(y)
    if String.length(y) == 2, do: 2000 + n, else: n
  end

  defp first_season(seasons) do
    with %{seasons: [%{id: sid, year: year} | _], tournament_id: tid} <- List.first(seasons) do
      {tid, sid, to_string(year)}
    else
      _ -> nil
    end
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: nil

  @doc """
  Narrows a round's events to the phase nearest to now.

  Argentine seasons run two tournaments under one Sofascore season, and both
  phases reuse the same round numbers — so round 1 of season 87913 returns 30
  events: 15 played in January (Apertura) and 15 scheduled for July (Clausura).
  Rendering all of them mixes a six-month-old matchday into "la fecha".

  Anchors on the event closest in time to `now` and keeps everything within
  `window_days` of it, which holds whether the fecha is upcoming or just
  played. Returns the input untouched when there's nothing to split.
  """
  def current_phase(events, opts \\ [])

  def current_phase([], _opts), do: []

  def current_phase(events, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.to_unix()
    window = Keyword.get(opts, :window_days, 12) * 86_400

    anchor =
      events
      |> Enum.filter(&is_integer(&1["startTimestamp"]))
      |> Enum.min_by(&abs(&1["startTimestamp"] - now), fn -> nil end)

    case anchor do
      nil ->
        events

      %{"startTimestamp" => anchor_ts} ->
        Enum.filter(events, fn e ->
          is_integer(e["startTimestamp"]) and abs(e["startTimestamp"] - anchor_ts) <= window
        end)
    end
  end

  @doc """
  Fixtures for one round (fecha) of the league (unique-tournament 155), for the
  configured season. `{:ok, [event]}`, `{:error, :no_season}` or `{:error, reason}`.

  Cached 10 min — a round's schedule is stable; live scores within it may lag by
  up to that window.
  """
  def round_fixtures(round) when is_integer(round) do
    case round_fixtures_cached(round) do
      {:ok, evs, _source} -> {:ok, evs}
      other -> other
    end
  end

  @doc """
  Like `round_fixtures/1`, but also reports where the data came from:
  `{:ok, events, :cached | :live}`.

  Callers surface this so a reader can tell a freshly fetched round from one
  served out of the 10-minute cache — which matters when a match is in play and
  the score may be up to that stale.
  """
  def round_fixtures_cached(round) when is_integer(round) do
    case current_season_id() do
      nil ->
        {:error, :no_season}

      season ->
        key = "sofascore:round:#{season}:#{round}"

        case Cachex.get(:forum_cache, key) do
          {:ok, evs} when is_list(evs) and evs != [] ->
            {:ok, evs, :cached}

          _ ->
            case api_get("/unique-tournament/155/season/#{season}/events/round/#{round}") do
              {:ok, %{"events" => evs}} when is_list(evs) ->
                Cachex.put(:forum_cache, key, evs, ttl: :timer.minutes(10))
                {:ok, evs, :live}

              {:ok, other} ->
                require Logger
                Logger.warning("[Sofascore] round #{round}: unexpected body shape: #{inspect(other) |> String.slice(0, 200)}")
                {:error, :no_fixtures}

              err ->
                require Logger
                Logger.warning("[Sofascore] round #{round} (season #{season}) fetch failed: #{inspect(err)}")
                err
            end
        end
    end
  end

  @doc """
  A single event (match) by id, for its live status and score.

  Not cached: ResultaBot polls this to decide whether a match is still in play,
  and a stale answer would either miss the kickoff or keep polling past the
  final whistle.
  """
  def event(event_id) when is_integer(event_id) do
    case api_get("/event/#{event_id}") do
      {:ok, %{"event" => event}} -> {:ok, event}
      {:ok, _} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every incident for an event — goals, cards, substitutions, period markers.

  `goals/1` filters this same feed down to goals; ResultaBot needs the rest too.
  Each incident carries a stable Sofascore `id`, which is what makes reliable
  de-duplication across polls possible.

  15s cache: a live poll and a page view moments apart shouldn't both hit the
  API, but the window has to stay well under the poll interval.
  """
  def incidents(event_id) when is_integer(event_id) do
    key = "sofascore:incidents:#{event_id}"

    case Cachex.get(:forum_cache, key) do
      {:ok, list} when is_list(list) ->
        list

      _ ->
        list =
          case api_get("/event/#{event_id}/incidents") do
            {:ok, %{"incidents" => inc}} when is_list(inc) -> inc
            _ -> []
          end

        Cachex.put(:forum_cache, key, list, ttl: :timer.seconds(15))
        list
    end
  end

  @doc """
  Flattens an `event/1` payload into the shape the match banner renders.

  Lives here rather than in the LiveView so the poller and the page agree on
  what "the score right now" means — the banner is fed from both.
  """
  def match_summary(event) when is_map(event) do
    %{
      home: get_in(event, ["homeTeam", "name"]),
      away: get_in(event, ["awayTeam", "name"]),
      home_id: get_in(event, ["homeTeam", "id"]),
      away_id: get_in(event, ["awayTeam", "id"]),
      home_score: get_in(event, ["homeScore", "current"]) || 0,
      away_score: get_in(event, ["awayScore", "current"]) || 0,
      status: banner_status(event),
      minute: get_in(event, ["time", "currentPeriodStartTimestamp"]) && nil,
      competition: competition_label(event),
      kickoff: kickoff_label(event["startTimestamp"])
    }
  end

  defp banner_status(event) do
    case get_in(event, ["status", "type"]) do
      "inprogress" -> if halftime?(event), do: :halftime, else: :live
      "notstarted" -> :prematch
      "finished" -> :finished
      _ -> :finished
    end
  end

  defp halftime?(event) do
    get_in(event, ["status", "description"]) in ["Halftime", "HT"]
  end

  defp competition_label(event) do
    name = get_in(event, ["tournament", "name"])
    round = get_in(event, ["roundInfo", "round"])

    case {name, round} do
      {nil, _} -> ""
      {n, nil} -> n
      {n, r} -> "#{n} · Fecha #{r}"
    end
  end

  defp kickoff_label(nil), do: "--:--"

  defp kickoff_label(ts) do
    ts
    |> DateTime.from_unix!(:second)
    |> DateTime.shift_zone!("America/Argentina/Buenos_Aires")
    |> Calendar.strftime("%H:%M")
  rescue
    _ -> "--:--"
  end

  @doc """
  Whether an event is currently being played, from a `event/1` payload.
  """
  def live?(%{"status" => %{"type" => type}}), do: type == "inprogress"
  def live?(_), do: false

  defp api_get(path) do
    case Req.get("#{api_base()}#{path}",
           headers: %{"user-agent" => @user_agent, "accept" => "application/json"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, error} -> {:error, error}
    end
  end
end
