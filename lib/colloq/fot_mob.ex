defmodule Colloq.FotMob do
  @moduledoc """
  Liga Profesional standings and calendar from FotMob — the fallback for when
  Sofascore, the primary source, can't answer.

  Same undocumented endpoint `Colloq.CopaArgentina` uses (`/api/data/leagues`,
  note the `data` segment), different league id. That module stays separate on
  purpose: Copa Argentina has *no* Sofascore equivalent, so it's a primary
  source there and a fallback here, and collapsing the two would hide which
  provider actually answered.

  Rows are mapped into the shape `Colloq.Sofascore.StandingsSvg` already draws,
  so the fallback renders through exactly the same path as the primary. Two
  things FotMob doesn't give us survive the mapping as gaps rather than
  guesses: zone/promotion labels (it encodes those as legend colours, not text)
  and the annual/averages tables (null on this feed).

  The whole payload is cached for 30 minutes.
  """

  require Logger

  @league_id 112
  @base "https://www.fotmob.com/api/data/leagues"
  @teams_base "https://www.fotmob.com/api/data/teams"
  # Sofascore's id for the same league; stamped on converted league events so
  # callers can tell a league match from a cup one without knowing the source.
  @sofascore_league_id 155
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  @cache_key "fotmob:liga:112"
  @ttl :timer.minutes(30)

  @doc """
  Current tournament's zone tables, as `{:ok, [{label, rows}]}`.

  FotMob returns every tournament of the season at once ("Clausura - Group A",
  "Apertura - Group A", …), current one first. We keep only the first
  tournament's zones, which is the running one — the same thing `/tabla` means.
  """
  def liga_standings do
    with {:ok, payload} <- league() do
      tables =
        payload
        |> get_in(["table"])
        |> List.wrap()
        |> List.first(%{})
        |> Map.get("data", %{})
        |> Map.get("tables", [])
        |> List.wrap()

      case current_tournament(tables) do
        [] -> {:error, :no_tables}
        current -> {:ok, Enum.map(current, &{label(&1), rows(&1)})}
      end
    end
  end

  # Tables are named "<Tournament> - Group <X>"; keep the ones belonging to the
  # tournament that appears first.
  defp current_tournament(tables) do
    case tables do
      [] ->
        []

      [first | _] ->
        tournament = tournament_of(first)
        Enum.filter(tables, &(tournament_of(&1) == tournament))
    end
  end

  defp tournament_of(table) do
    (table["leagueName"] || "") |> String.split(" - ") |> List.first() |> to_string()
  end

  # "Clausura - Group A" → "Clausura · Grupo A"
  defp label(table) do
    (table["leagueName"] || "")
    |> String.replace(~r/\bgroup\b/i, "Grupo")
    |> String.replace(" - ", " · ")
  end

  defp rows(table) do
    table
    |> get_in(["table", "all"])
    |> List.wrap()
    |> Enum.map(&map_row/1)
  end

  # FotMob row → the Sofascore row shape StandingsSvg draws.
  defp map_row(row) do
    {goals_for, goals_against} = parse_scores(row["scoresStr"])

    %{
      "position" => row["idx"],
      "team" => %{
        "name" => row["name"] || row["shortName"],
        "id" => row["id"],
        # FotMob ids don't resolve against Sofascore's crest host, so carry the
        # image URL explicitly rather than letting the renderer build one.
        "crest" => row["id"] && "https://images.fotmob.com/image_resources/logo/teamlogo/#{row["id"]}.png"
      },
      "matches" => row["played"],
      "wins" => row["wins"],
      "draws" => row["draws"],
      "losses" => row["losses"],
      "scoresFor" => goals_for,
      "scoresAgainst" => goals_against,
      "scoreDiffFormatted" => fmt_diff(row["goalConDiff"]),
      "points" => row["pts"]
    }
  end

  # "19-7" → {19, 7}
  defp parse_scores(str) when is_binary(str) do
    case String.split(str, "-") do
      [f, a] -> {to_int(f), to_int(a)}
      _ -> {0, 0}
    end
  end

  defp parse_scores(_), do: {0, 0}

  defp to_int(str) do
    case str |> String.trim() |> Integer.parse() do
      {n, _} -> n
      :error -> 0
    end
  end

  defp fmt_diff(d) when is_integer(d) and d > 0, do: "+#{d}"
  defp fmt_diff(d) when is_integer(d), do: to_string(d)
  defp fmt_diff(_), do: "0"

  # ===========================================================================
  # Calendar fallback
  #
  # When Sofascore refuses us and there's no saved copy, the calendar is rebuilt
  # from FotMob and converted into the Sofascore event shape the rest of the app
  # already reads (`homeTeam`, `status.type`, `startTimestamp`, `roundInfo`...).
  #
  # Event ids are prefixed "fotmob:" and team ids are nil: neither maps onto a
  # Sofascore id, so a fallback event can't be mistaken for one (predictions are
  # keyed by Sofascore event id, and crests are Sofascore team images).
  # ===========================================================================

  @doc "League fixtures for one fecha, as Sofascore-shaped events."
  def league_round_events(round) when is_integer(round) do
    with {:ok, payload} <- league() do
      {:ok,
       payload
       |> all_league_matches()
       |> Enum.filter(&(league_round(&1) == round))
       |> Enum.map(&league_event/1)}
    end
  end

  @doc """
  Every fixture (all competitions) for the team with this name, as
  Sofascore-shaped events. The name is matched against the league feed, which
  is where FotMob's team id comes from.
  """
  def team_events(team_name) when is_binary(team_name) do
    with {:ok, payload} <- league(),
         {:ok, team_id} <- find_team_id(payload, team_name),
         {:ok, team} <- team(team_id) do
      rounds = Map.new(all_league_matches(payload), &{to_string(&1["id"]), league_round(&1)})

      events =
        team
        |> get_in(["fixtures", "allFixtures", "fixtures"])
        |> List.wrap()
        |> Enum.map(fn m ->
          league_id = get_in(m, ["tournament", "leagueId"])
          league? = league_id == @league_id
          round = if league?, do: rounds[to_string(m["id"])]
          # Never nil for a cup tie: callers treat a missing tournament id as
          # "could be the league" (older Sofascore payloads), so it must say it isn't.
          tournament_id = if league?, do: @sofascore_league_id, else: "fotmob:#{league_id}"

          to_event(m, get_in(m, ["tournament", "name"]), round, tournament_id)
        end)

      {:ok, events}
    end
  end

  @doc """
  Brings a FotMob event (from `team_events/1` or `league_round_events/1`) up to
  the minute: score, status and live minute from the match-details feed.

  The team and league feeds are not live — during a match the team feed still
  reported minute 1 and 0:0 twenty minutes in — so anything showing a match in
  play (the score banner) reads the details feed. Returns the event unchanged
  if that fetch fails.
  """
  def refresh_live(%{"id" => "fotmob:" <> match_id} = event) do
    case match_details(match_id) do
      {:ok, %{"header" => %{"status" => %{} = status, "teams" => [home, away | _]}}} ->
        type = status_type(status)
        live? = type == "inprogress"

        event
        |> Map.put("status", %{
          "type" => type,
          "description" => if(halftime?(status), do: "Halftime")
        })
        |> Map.put("homeScore", %{"current" => if(type != "notstarted", do: home["score"])})
        |> Map.put("awayScore", %{"current" => if(type != "notstarted", do: away["score"])})
        |> Map.put("liveMinute", if(live?, do: live_minute(status)))

      _ ->
        event
    end
  end

  def refresh_live(event), do: event

  defp match_details(match_id) do
    key = "fotmob:match:#{match_id}"

    case Cachex.get(:forum_cache, key) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      _ ->
        with {:ok, payload} <- fetch("https://www.fotmob.com/api/data/matchDetails?matchId=#{match_id}") do
          Cachex.put(:forum_cache, key, payload, ttl: :timer.seconds(30))
          {:ok, payload}
        end
    end
  end

  defp all_league_matches(payload),
    do: payload |> get_in(["fixtures", "allMatches"]) |> List.wrap()

  # "7" (Apertura) or "Clausura - Round 7" → 7. Playoff rounds ("Apertura -
  # Final") have no fecha number and are left out.
  defp league_round(%{"round" => round}) do
    case Regex.run(~r/^(?:.*Round )?(\d+)$/, to_string(round)) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp league_round(_), do: nil

  defp league_event(m), do: to_event(m, "Liga Profesional", league_round(m), @sofascore_league_id)

  defp find_team_id(payload, name) do
    wanted = String.downcase(name)

    payload
    |> all_league_matches()
    |> Enum.flat_map(&[&1["home"], &1["away"]])
    |> Enum.find(&(is_map(&1) and String.downcase(to_string(&1["name"])) == wanted))
    |> case do
      %{"id" => id} -> {:ok, id}
      _ -> {:error, :team_not_found}
    end
  end

  defp to_event(m, tournament, round, tournament_id) do
    status = m["status"] || %{}
    type = status_type(status)
    {home_score, away_score} = if type == "notstarted", do: {nil, nil}, else: scores(m)

    %{
      "id" => "fotmob:#{m["id"]}",
      "source" => "fotmob",
      "homeTeam" => team_side(m["home"]),
      "awayTeam" => team_side(m["away"]),
      # Only set on a match in play; the banner shows it next to the score.
      "liveMinute" => if(type == "inprogress", do: live_minute(status)),
      "homeScore" => %{"current" => home_score},
      "awayScore" => %{"current" => away_score},
      "startTimestamp" => timestamp(status["utcTime"]),
      "status" => %{"type" => type, "description" => if(halftime?(status), do: "Halftime")},
      "roundInfo" => if(round, do: %{"round" => round}),
      "tournament" => %{
        "name" => tournament,
        "uniqueTournament" => %{"id" => tournament_id}
      }
    }
  end

  # FotMob team ids are not Sofascore's, so "id" stays nil; the crest comes
  # from FotMob's own image host instead.
  defp team_side(side) when is_map(side) do
    %{
      "name" => side["name"],
      "id" => nil,
      "crest" => side["id"] && "https://images.fotmob.com/image_resources/logo/teamlogo/#{side["id"]}.png"
    }
  end

  defp team_side(_), do: %{"name" => nil, "id" => nil}

  # liveTime.short is "34’" or "45+2’"; "HT" at half-time.
  defp live_minute(status) do
    case get_in(status, ["liveTime", "short"]) do
      short when is_binary(short) ->
        case Regex.run(~r/^\d+(\+\d+)?/, short) do
          [minute | _] -> minute
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp halftime?(status) do
    get_in(status, ["liveTime", "short"]) == "HT" or get_in(status, ["reason", "short"]) == "HT"
  end

  defp status_type(%{"cancelled" => true}), do: "canceled"
  defp status_type(%{"finished" => true}), do: "finished"
  defp status_type(%{"started" => true}), do: "inprogress"
  defp status_type(_), do: "notstarted"

  # The league feed carries "2 - 1"; the team feed carries per-side scores.
  defp scores(%{"status" => %{"scoreStr" => str}}) when is_binary(str) do
    case Regex.run(~r/^\s*(\d+)\s*-\s*(\d+)/, str) do
      [_, h, a] -> {String.to_integer(h), String.to_integer(a)}
      _ -> {nil, nil}
    end
  end

  defp scores(m), do: {get_in(m, ["home", "score"]), get_in(m, ["away", "score"])}

  defp timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  defp team(team_id) do
    key = "fotmob:team:#{team_id}"

    case Cachex.get(:forum_cache, key) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      _ ->
        with {:ok, payload} <- fetch("#{@teams_base}?id=#{team_id}") do
          # Short: this backs the live score banner while Sofascore is out.
          Cachex.put(:forum_cache, key, payload, ttl: :timer.minutes(1))
          {:ok, payload}
        end
    end
  end

  defp league do
    case Cachex.get(:forum_cache, @cache_key) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      _ ->
        with {:ok, payload} <- fetch("#{@base}?id=#{@league_id}") do
          Cachex.put(:forum_cache, @cache_key, payload, ttl: @ttl)
          {:ok, payload}
        end
    end
  end

  defp fetch(url) do
    case Req.get(url,
           headers: %{"user-agent" => @user_agent, "accept" => "application/json"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      # An HTML body means FotMob served the SPA instead of JSON — usually the
      # sign that the undocumented endpoint moved.
      {:ok, %{status: 200}} ->
        Logger.warning("[FotMob] non-JSON body — endpoint may have changed")
        {:error, :unexpected_payload}

      {:ok, %{status: status}} ->
        Logger.warning("[FotMob] status #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[FotMob] request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
