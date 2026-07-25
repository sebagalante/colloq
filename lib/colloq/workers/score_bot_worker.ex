defmodule Colloq.Workers.ScoreBotWorker do
  @moduledoc """
  Match day score bot worker — the heart of the live match experience.
  Posts to the forum as **ResultaBot** (the module keeps its original name so
  existing references elsewhere stay valid).

  Cron: 9:00 AM daily → fixture preview post.
  During a match: polls **Sofascore** every 75s (`:scorebot_poll_seconds`) for
  goals, cards, substitutions and in-play penalties. The loop is self-scheduling
  and is started by `start_polling/2` — the cron does not start it. `fixture_id`
  in the job args is a Sofascore *event* id.
  On FT (the match leaves "inprogress" for a finished status): the loop stops on
  its own and `finalize_match/3` posts the final result and the updated
  standings, posts a "coverage ended" note, and flips the thread to fulltime.
  Prediction scoring is left to the nightly PredictionDigestWorker sweep.
  Broadcasts {:match_mode_changed, topic_id, mode} and {:match_event, topic_id, data} via PubSub.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 5
  require Logger
  import Ecto.Query
  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Forum.Topic
  alias Colloq.Sofascore

  @doc """
  Racing Club de Avellaneda's **API-Football** team id.

  Team ids are per-provider and do not transfer: the same club is 3215 on
  Sofascore (`Colloq.Sofascore.racing_team_id/0`) and 436 here. Confirmed via
  `/teams?name=Racing Club`, which returns *two* clubs of that exact name —
  436 (Argentina, founded 1903, Estadio Presidente Perón) and 10123
  (Guadeloupe) — so match on country, never on name alone.
  """
  def racing_team_id, do: 436

  @impl Oban.Worker
  def perform(%{args: %{"action" => "preview"}}) do
    match_threads = Repo.all(
      from(t in Topic, where: t.is_match_thread == true and t.match_mode == "prematch")
    )

    Enum.each(match_threads, fn topic ->
      create_preview_post(topic)
    end)

    {:ok, length(match_threads)}
  end

  @impl Oban.Worker
  def perform(%{args: %{"action" => "poll", "fixture_id" => fixture_id, "topic_id" => topic_id}}) do
    # topic_id comes back from Oban's JSON args as an integer (start_polling/2
    # passes topic.id), so String.to_integer/1 raised on every poll. to_int/1
    # accepts either shape.
    topic = Forum.get_topic!(to_int(topic_id))

    case fetch_live_events(fixture_id, topic.id) do
      {:ok, events} ->
        # Every poll returns the fixture's FULL event list, so without this the
        # same goal is re-posted on each tick for the rest of the match. Events
        # already posted are identified by a stable key stored in event_data.
        already_posted = posted_event_keys(topic.id)

        new_events = Enum.reject(events, &MapSet.member?(already_posted, event_key(&1)))

        Enum.each(new_events, fn event ->
          create_event_post(topic, event)
          broadcast_event(topic.id, event)
        end)

        # Queue the next poll — this is what makes it a loop. Re-read the topic
        # first: cancelling the queued job is not enough to stop coverage,
        # because a poll already executing would just schedule its own
        # successor and the loop would survive the stop.
        maybe_schedule_next_poll(fixture_id, topic_id)

        {:ok, length(new_events)}

      {:finished, event} ->
        finalize_match(topic, fixture_id, event)
        {:ok, :finished}

      {:pending, _event} ->
        # Match not live yet — keep polling until it kicks off.
        maybe_schedule_next_poll(fixture_id, topic_id)
        {:ok, :pending}

      {:error, _reason} ->
        {:snooze, 30}
    end
  end

  def perform(%{args: %{"action" => "ft_summary", "fixture_id" => fixture_id, "topic_id" => topic_id}}) do
    topic = Forum.get_topic!(topic_id)

    # Post match summary
    body = build_ft_summary(fixture_id)
    system_user = get_or_create_scorebot_user()
    Forum.create_post(topic, system_user, %{"body" => body, "is_system" => true, "system_type" => "summary"})

    # Transition to fulltime mode
    Forum.set_match_mode(topic, "fulltime")
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "match_mode_changed", %{mode: "fulltime"})

    # Trigger scoring
    Colloq.Workers.PredictionScorerWorker.new(%{fixture_id: fixture_id, topic_id: topic_id})
    |> Oban.insert()

    {:ok, :summary_posted}
  end

  # --- API call ---

  # Source is Sofascore, not API-Football: the free API-Football plan can only
  # read seasons 2022-2024 ("Free plans do not have access to this season"), so
  # it cannot follow a current Racing match at all. Sofascore needs no key, has
  # no quota, is already the source for the fixture digest, and its incidents
  # carry stable ids that make de-duplication exact.
  defp fetch_live_events(event_id, topic_id) do
    event_id = to_int(event_id)

    case Sofascore.event(event_id) do
      {:ok, event} ->
        # Push the score to every open thread on each poll, live or not: the
        # banner should also settle on the final result rather than freeze on
        # the last in-play score.
        broadcast_score(topic_id, event)

        cond do
          Sofascore.live?(event) ->
            {:ok, event_id |> Sofascore.incidents() |> parse_events(event)}

          match_finished?(event) ->
            {:finished, event}

          # Not "inprogress" and not finished: the match hasn't kicked off yet
          # (coverage armed before kickoff) or a transient status. Keep the loop
          # alive rather than declaring full time on a match that never started.
          true ->
            {:pending, event}
        end

      {:error, reason} ->
        Logger.error("[ResultaBot] no se pudo leer el evento #{event_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp broadcast_score(topic_id, event) do
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "match_score", %{
      match: Sofascore.match_summary(event)
    })
  end

  # A match is over (not merely "not live") only for these terminal statuses;
  # "notstarted" must not count, or arming coverage early would end it at once.
  @finished_statuses ~w(finished canceled cancelled postponed)
  defp match_finished?(event), do: get_in(event, ["status", "type"]) in @finished_statuses

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)

  # --- Polling loop ---

  # How often to re-check a live match. One API call per poll, so a 2h match
  # costs ~30 requests at this interval — the free plan allows 100/day, which
  # leaves room for a match plus the preview and full-time calls.
  defp poll_interval_seconds do
    Application.get_env(:colloq, :scorebot_poll_seconds, 75)
  end

  # Coverage is "on" while the topic is in prematch/live. `/resultabot stop`
  # and the full-time transition both move it to "fulltime", which is what
  # actually breaks the chain.
  defp maybe_schedule_next_poll(fixture_id, topic_id) do
    case Repo.get(Topic, topic_id) do
      %Topic{match_mode: mode} when mode in ["prematch", "live"] ->
        schedule_next_poll(fixture_id, topic_id)

      _ ->
        Logger.info("[ResultaBot] cobertura detenida para el partido #{fixture_id}; no reprogramo")
        :stopped
    end
  end

  defp schedule_next_poll(fixture_id, topic_id) do
    %{action: "poll", fixture_id: fixture_id, topic_id: topic_id}
    |> new(
      schedule_in: poll_interval_seconds(),
      # Two overlapping loops for one fixture would double every alert; the
      # unique guard keeps a single chain alive per fixture. :executing is
      # deliberately excluded: the job doing the rescheduling is itself
      # executing, so counting that state made every poll dedup against itself
      # and the loop died after a single tick. Guarding on the pending states
      # (:available/:scheduled) still collapses two parallel chains into one.
      unique: [
        period: poll_interval_seconds() * 2,
        states: [:available, :scheduled],
        keys: [:action, :fixture_id]
      ]
    )
    |> Oban.insert()
  end

  @doc """
  Starts the polling loop for a fixture. Call this when a match kicks off —
  nothing schedules the loop on its own.
  """
  def start_polling(fixture_id, topic_id) do
    %{action: "poll", fixture_id: fixture_id, topic_id: topic_id}
    |> new()
    |> Oban.insert()
  end

  # --- Event dedup ---

  # Sofascore gives every incident a stable unique id, so that IS the identity —
  # no composite key to collide. Verified on a real match: 18 events, 18
  # distinct ids.
  @doc false
  def event_key(%{id: id}) when not is_nil(id), do: to_string(id)

  # Fallback for payloads without an id (older cached shapes, other providers).
  def event_key(event) do
    [event[:type], event[:detail], event[:team], event[:player], event[:minute]]
    |> Enum.map(&to_string/1)
    |> Enum.join("|")
  end

  defp posted_event_keys(topic_id) do
    Repo.all(
      from(p in Colloq.Forum.Post,
        where: p.topic_id == ^topic_id and p.is_system == true and not is_nil(p.event_data),
        select: fragment("? ->> 'key'", p.event_data)
      )
    )
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # --- Event parsing ---

  # Posted live: goals, cards, substitutions and in-play penalties (misses and
  # saves — a *scored* penalty already arrives as a goal with incidentClass
  # "penalty", so it isn't duplicated here). Period markers, VAR reviews and
  # injury-time notices stay out; they belong in the full-time summary.
  @posted_incident_types ~w(goal card substitution inGamePenalty)

  @doc false
  def parse_events(incidents, event) do
    home = get_in(event, ["homeTeam", "name"]) || "Local"
    away = get_in(event, ["awayTeam", "name"]) || "Visitante"

    incidents
    |> Enum.filter(&(&1["incidentType"] in @posted_incident_types))
    |> Enum.map(&parse_incident(&1, home, away))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.minute || 0))
  end

  defp parse_incident(%{"incidentType" => "goal"} = i, home, away) do
    %{
      id: i["id"],
      type: "goal",
      minute: i["time"],
      team: side(i, home, away),
      player: player_name(i["player"]),
      detail: i["incidentClass"] || "regular",
      # Sofascore reports the running score with each goal, so the post can
      # show it without a second lookup.
      home_score: i["homeScore"],
      away_score: i["awayScore"]
    }
  end

  defp parse_incident(%{"incidentType" => "card"} = i, home, away) do
    %{
      id: i["id"],
      type: "card",
      minute: i["time"],
      team: side(i, home, away),
      player: player_name(i["player"]),
      detail: i["incidentClass"] || "yellow"
    }
  end

  defp parse_incident(%{"incidentType" => "substitution"} = i, home, away) do
    %{
      id: i["id"],
      type: "sub",
      minute: i["time"],
      team: side(i, home, away),
      player_in: player_name(i["playerIn"]),
      player_out: player_name(i["playerOut"]),
      injury: i["injury"] == true
    }
  end

  # In-play penalty event — in practice a miss or a save (a converted one comes
  # through as a goal). incidentClass tells missed/scored; reason says why.
  defp parse_incident(%{"incidentType" => "inGamePenalty"} = i, home, away) do
    %{
      id: i["id"],
      type: "penalty",
      minute: i["time"],
      team: side(i, home, away),
      player: player_name(i["player"]),
      detail: i["incidentClass"] || "missed",
      reason: i["reason"]
    }
  end

  defp parse_incident(_incident, _home, _away), do: nil

  defp side(%{"isHome" => true}, home, _away), do: home
  defp side(_incident, _home, away), do: away

  defp player_name(%{"name" => name}) when is_binary(name), do: name
  defp player_name(_), do: "?"

  # --- Post creation ---

  defp create_preview_post(topic) do
    system_user = get_or_create_scorebot_user()

    # TODO: build a real preview (kickoff time, competition, lineups) from the
    # fixture endpoint. Placeholder until the API key is available to verify
    # the payload shape against a live Racing fixture.
    Forum.create_post(topic, system_user, %{
      "body" => "⚽ Vista previa del partido",
      "is_system" => true,
      "system_type" => "preview"
    })
  end

  defp create_event_post(topic, event) do
    system_user = get_or_create_scorebot_user()

    {type_label, body} = render_event(event)

    Forum.create_post(topic, system_user, %{
      "body" => body,
      "is_system" => true,
      "system_type" => type_label,
      # The key is what posted_event_keys/1 reads back to skip this event on
      # the next poll; without it stored, dedup silently never matches.
      "event_data" => Map.put(event, :key, event_key(event))
    })
  end

  @doc false
  def render_event(%{type: "goal"} = e) do
    kind =
      case e.detail do
        "penalty" -> " (de penal)"
        "ownGoal" -> " (en contra)"
        _ -> ""
      end

    score =
      if e[:home_score] && e[:away_score], do: " — #{e.home_score}-#{e.away_score}", else: ""

    {"goal", "⚽ ¡GOOOL de #{e.team}! #{e.player} #{e.minute}'#{kind}#{score}"}
  end

  def render_event(%{type: "card"} = e) do
    {icon, label} =
      case e.detail do
        "yellow" -> {"🟨", "Amarilla"}
        "yellowRed" -> {"🟥", "Doble amarilla"}
        _ -> {"🟥", "Roja"}
      end

    {"card", "#{icon} #{label} — #{e.player} (#{e.team}) #{e.minute}'"}
  end

  def render_event(%{type: "sub"} = e) do
    tag = if e[:injury], do: " (lesión)", else: ""
    {"sub", "🔄 Cambio en #{e.team}: entra #{e.player_in}, sale #{e.player_out} #{e.minute}'#{tag}"}
  end

  def render_event(%{type: "penalty"} = e) do
    {icon, label} =
      case e.detail do
        "scored" -> {"⚽", "Penal convertido"}
        _ -> {"❌", "Penal errado"}
      end

    {"penalty", "#{icon} #{label} — #{e.player} (#{e.team}) #{e.minute}'#{penalty_reason(e[:reason])}"}
  end

  def render_event(e) do
    {"event", "#{e.type} — #{e[:player]} #{e[:minute]}'"}
  end

  defp penalty_reason("goalkeeperSave"), do: " (atajado)"
  defp penalty_reason("post"), do: " (al palo)"
  defp penalty_reason("miss"), do: " (afuera)"
  defp penalty_reason(_), do: ""

  defp build_ft_summary(_fixture_id) do
    # TODO: fetch actual fixture data to build summary
    "⚡ ¡Final del partido!"
  end

  # --- PubSub ---

  defp broadcast_event(topic_id, event) do
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "match_event", %{
      type: event.type,
      player: event.player,
      minute: event.minute,
      detail: event.detail,
      team: event.team
    })
  end

  defp transition_to_fulltime(topic) do
    Forum.set_match_mode(topic, "fulltime")
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "match_mode_changed", %{mode: "fulltime"})
  end

  # Automatic full time: the match left "inprogress" for a finished status. Post
  # the final result and the updated standings, tell readers coverage is over,
  # then flip the thread to fulltime — which also stops the loop, since
  # maybe_schedule_next_poll won't reschedule once the mode isn't live.
  # Prediction scoring is intentionally left to the nightly PredictionDigestWorker
  # sweep rather than fired here.
  defp finalize_match(topic, _fixture_id, event) do
    # Re-read of the mode fetched at poll start: skip the posts if a prior tick
    # already finalized, but always (idempotently) assert fulltime.
    if topic.match_mode != "fulltime" do
      post_final_result(topic, event)
      post_standings(topic, event)
      post_coverage_ended(topic)
    end

    transition_to_fulltime(topic)
  end

  defp post_final_result(topic, event) do
    s = Sofascore.match_summary(event)

    Forum.create_post(topic, get_or_create_scorebot_user(), %{
      "body" => "🏁 <strong>Final</strong> — #{s.home} #{s.home_score} - #{s.away_score} #{s.away}",
      "is_system" => true,
      "system_type" => "summary"
    })
  end

  defp post_standings(topic, event) do
    season_id = get_in(event, ["season", "id"]) || Sofascore.current_season_id()

    with true <- is_integer(season_id),
         {:ok, data} <- Sofascore.standings(season_id),
         rows when rows != [] <- standings_rows(data) do
      svg = Colloq.Sofascore.StandingsSvg.render(rows)

      Forum.create_post(topic, get_or_create_scorebot_user(), %{
        "body" => "📊 Tabla de Posiciones — Liga Profesional",
        "is_system" => true,
        "system_type" => "standings",
        "event_data" => %{"season_id" => season_id, "svg" => svg}
      })
    else
      _ -> :ok
    end
  end

  # The /standings/total payload carries every zone (Clausura/Apertura Group A
  # and B) plus the aggregate Anual and Promedios tables — six in all. Flattening
  # them produced a 120-row wall; we only want Racing's own group. Pick the first
  # table that actually contains Racing, falling back to the flattened rows if
  # none does (e.g. a single-table competition).
  defp standings_rows(%{"standings" => tables}) when is_list(tables) do
    racing = Sofascore.racing_team_id()

    case Enum.find(tables, &group_has_team?(&1, racing)) do
      %{"rows" => rows} when is_list(rows) -> rows
      _ -> Enum.flat_map(tables, &Map.get(&1, "rows", []))
    end
  end

  defp standings_rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp standings_rows(_), do: []

  defp group_has_team?(table, team_id) do
    table
    |> Map.get("rows", [])
    |> Enum.any?(&(get_in(&1, ["team", "id"]) == team_id))
  end

  defp post_coverage_ended(topic) do
    Forum.create_post(topic, get_or_create_scorebot_user(), %{
      "body" =>
        "🛑 <strong>ResultaBot</strong> — fin de la cobertura. ¡Gracias por seguir el partido!",
      "is_system" => true,
      "system_type" => "bot_status"
    })
  end

  # --- System user ---

  # The user-facing bot is ResultaBot. The module keeps its ScoreBot name so the
  # existing references in PredictionScorer/PushNotification and the post-type
  # docs stay valid — only what readers see on the forum is renamed.
  @bot_username "resultabot"

  @doc """
  The ResultaBot forum account, created on first use.
  """
  def bot_user, do: get_or_create_scorebot_user()

  defp get_or_create_scorebot_user do
    case Colloq.Accounts.get_user_by_username(@bot_username) do
      nil ->
        {:ok, user} =
          Colloq.Accounts.register_bot(%{
            email: "#{@bot_username}@colloq.local",
            username: @bot_username,
            display_name: "ResultaBot",
            password: "#{@bot_username}-internal",
            password_confirmation: "#{@bot_username}-internal"
          })

        user

      user ->
        user
    end
  end
end