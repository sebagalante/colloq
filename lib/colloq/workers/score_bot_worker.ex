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
  def perform(%{args: %{"action" => "poll", "fixture_id" => fixture_id, "topic_id" => topic_id} = args}) do
    # topic_id comes back from Oban's JSON args as an integer (start_polling/2
    # passes topic.id), so String.to_integer/1 raised on every poll. to_int/1
    # accepts either shape.
    topic = Forum.get_topic!(to_int(topic_id))

    case fetch_live(topic, fixture_id, args) do
      {:live, live, events} ->
        maybe_post_team_sheet(topic, fixture_id, live, true)

        # Every poll returns the fixture's FULL event list, so without this the
        # same goal is re-posted on each tick for the rest of the match. Events
        # already posted are identified by a stable key stored in event_data.
        posted = posted_events(topic.id)
        new_events = Enum.reject(events, &already_posted?(&1, live.source, posted))

        Enum.each(new_events, fn event ->
          create_event_post(topic, event, live.source)
          broadcast_event(topic.id, event)
        end)

        # Queue the next poll — this is what makes it a loop. Re-read the topic
        # first: cancelling the queued job is not enough to stop coverage,
        # because a poll already executing would just schedule its own
        # successor and the loop would survive the stop.
        maybe_schedule_next_poll(fixture_id, topic.id, live.args)

        {:ok, length(new_events)}

      {:finished, live} ->
        finalize_match(topic, fixture_id, live.event)
        {:ok, :finished}

      {:pending, live} ->
        # Match not live yet — keep polling until it kicks off. Lineups usually
        # land during this window, which is the whole point of posting them from
        # here rather than at kickoff.
        maybe_post_team_sheet(topic, fixture_id, live, false)
        maybe_schedule_next_poll(fixture_id, topic.id, live.args)
        {:ok, :pending}

      # Neither provider answered. Used to `{:snooze, 30}`, but a snooze never
      # counts as an attempt, so a block kept a week-old thread "live" and
      # polling forever.
      :unreachable ->
        continue_or_give_up(topic, fixture_id, args)
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

  # The match-day data source (`Colloq.DataSource`) is asked first and the
  # other provider fills in when it can't answer, so a Sofascore block (usually
  # a 403) no longer reduces coverage to the score banner.
  #
  # Not API-Football: the free plan can only read seasons 2022-2024 ("Free
  # plans do not have access to this season"), so it cannot follow a current
  # Racing match at all.
  #
  # Returns `{:live, live, events}`, `{:finished, live}`, `{:pending, live}` or
  # `:unreachable`, where `live` is `%{source, event, ref, args}`: the provider
  # that answered, its event, the id to ask it for lineups with, and the job
  # args to carry to the next poll.
  defp fetch_live(topic, fixture_id, args) do
    Colloq.DataSource.order(:matchday)
    |> Enum.find_value(:unreachable, &fetch_from(&1, topic, fixture_id, args))
  end

  defp fetch_from(:sofascore, topic, fixture_id, args) do
    event_id = to_int(fixture_id)

    case Sofascore.event(event_id) do
      {:ok, event} ->
        live = %{source: :sofascore, event: event, ref: event_id, args: carried_args(args)}
        classify(topic, live, fn -> event_id |> Sofascore.incidents() |> parse_events(event) end)

      {:error, reason} ->
        Logger.error("[ResultaBot] no se pudo leer el evento #{event_id}: #{inspect(reason)}")
        nil
    end
  end

  # FotMob has no mapping from the thread's Sofascore id, so the match is found
  # by the thread's title once and its id carried in the job args after that.
  defp fetch_from(:fotmob, topic, _fixture_id, args) do
    with match_id when is_binary(match_id) <- args["fotmob_id"] || find_fotmob_match(topic),
         {:ok, event} <- Colloq.FotMob.match_event(match_id) do
      live = %{
        source: :fotmob,
        event: event,
        ref: match_id,
        args: Map.put(carried_args(args), "fotmob_id", match_id)
      }

      classify(topic, live, fn ->
        case Colloq.FotMob.incidents(match_id) do
          {:ok, incidents} -> parse_events(incidents, event)
          _ -> []
        end
      end)
    else
      _ ->
        Logger.warning("[ResultaBot] FotMob no tiene el partido del topic #{topic.id}")
        nil
    end
  end

  defp find_fotmob_match(topic) do
    case Sofascore.fotmob_match_for_title(topic.title, topic.inserted_at) do
      {:ok, event} -> Colloq.FotMob.match_id(event)
      :error -> nil
    end
  end

  # Only what must survive between polls. `failing_since` is dropped on purpose:
  # a provider answered, so the outage clock starts over.
  defp carried_args(args), do: Map.take(args, ["fotmob_id"])

  defp classify(topic, live, events_fun) do
    # Push the score to every open thread on each poll, live or not: the
    # banner should also settle on the final result rather than freeze on
    # the last in-play score.
    broadcast_score(topic.id, live.event)

    cond do
      Sofascore.live?(live.event) ->
        {:live, live, events_fun.()}

      match_finished?(live.event) ->
        {:finished, live}

      # Not "inprogress" and not finished: the match hasn't kicked off yet
      # (coverage armed before kickoff) or a transient status. Keep the loop
      # alive rather than declaring full time on a match that never started.
      true ->
        {:pending, live}
    end
  end

  # How long a thread may go without either provider answering before coverage
  # stops on its own. Covers a full match plus extra time and penalties.
  @give_up_after_seconds 4 * 3600

  defp continue_or_give_up(topic, fixture_id, args) do
    now = System.system_time(:second)
    failing_since = args["failing_since"] || now

    if now - failing_since >= @give_up_after_seconds do
      Logger.warning("[ResultaBot] sin datos del partido #{fixture_id} hace 4h; corto la cobertura")

      if topic.match_mode != "fulltime", do: post_coverage_ended(topic)
      transition_to_fulltime(topic)
      {:ok, :gave_up}
    else
      extra = Map.put(carried_args(args), "failing_since", failing_since)
      maybe_schedule_next_poll(fixture_id, topic.id, extra)
      {:ok, :unreachable}
    end
  end

  defp broadcast_score(topic_id, event) do
    match = Sofascore.match_summary(event)
    # Saved so the thread keeps its banner after coverage ends.
    Colloq.Forum.put_match_snapshot(topic_id, match)
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "match_score", %{match: match})
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
  defp maybe_schedule_next_poll(fixture_id, topic_id, extra_args) do
    case Repo.get(Topic, topic_id) do
      %Topic{match_mode: mode} when mode in ["prematch", "live"] ->
        schedule_next_poll(fixture_id, topic_id, extra_args)

      _ ->
        Logger.info("[ResultaBot] cobertura detenida para el partido #{fixture_id}; no reprogramo")
        :stopped
    end
  end

  # `extra_args` carries `fotmob_id`, and `failing_since` while no provider
  # answers; neither is part of the unique keys, so they never split one chain
  # into two.
  defp schedule_next_poll(fixture_id, topic_id, extra_args) do
    %{action: "poll", fixture_id: fixture_id, topic_id: topic_id}
    |> Map.merge(extra_args)
    |> new(
      schedule_in: poll_interval_seconds(),
      # Two overlapping loops for one fixture would double every alert; the
      # unique guard keeps a single chain alive per fixture. :executing is
      # deliberately excluded: the job doing the rescheduling is itself
      # executing, so counting that state made every poll dedup against itself
      # and the loop died after a single tick. Guarding on the pending states
      # (:available/:scheduled) still collapses two parallel chains into one.
      unique: poll_unique([:available, :scheduled])
    )
    |> Oban.insert()
  end

  @doc """
  Starts the polling loop for a fixture. Call this when a match kicks off —
  nothing schedules the loop on its own.

  A no-op while a chain for the fixture is already alive, including one that is
  mid-poll — running `/resultabot` twice used to start a second loop.
  """
  def start_polling(fixture_id, topic_id) do
    %{action: "poll", fixture_id: fixture_id, topic_id: topic_id}
    |> new(unique: poll_unique([:available, :scheduled, :executing, :retryable]))
    |> Oban.insert()
  end

  defp poll_unique(states) do
    [period: :infinity, states: states, keys: [:action, :fixture_id]]
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
    topic_id |> posted_events() |> Enum.map(& &1["key"]) |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  # event_data of every system post in the thread that has one, read back with
  # string keys (it went through JSON).
  defp posted_events(topic_id) do
    Repo.all(
      from(p in Colloq.Forum.Post,
        where: p.topic_id == ^topic_id and p.is_system == true and not is_nil(p.event_data),
        select: p.event_data
      )
    )
  end

  @doc false
  # Posted already: same key, or — when the data source changed mid-match — the
  # same moment as reported by the other provider. Keys don't carry over between
  # providers, so a goal is recognised by the score it produced, and anything
  # else by type, team and minute (±1, as the two clocks round differently).
  # Posts from before sources were recorded came from Sofascore.
  def already_posted?(event, source, posted) do
    key = event_key(event)
    source = to_string(source)

    Enum.any?(posted, fn p ->
      p["key"] == key or
        ((p["source"] || "sofascore") != source and same_moment?(event, p))
    end)
  end

  defp same_moment?(%{type: "goal"} = e, %{"type" => "goal"} = p) do
    is_integer(e[:home_score]) and e[:home_score] == p["home_score"] and
      e[:away_score] == p["away_score"]
  end

  defp same_moment?(%{type: type} = e, %{"type" => type} = p) do
    is_integer(e[:minute]) and is_integer(p["minute"]) and abs(e[:minute] - p["minute"]) <= 1 and
      Colloq.Predictions.FixtureMatch.team_similarity(e[:team], p["team"]) > 0
  end

  defp same_moment?(_event, _posted), do: false

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

  # --- Team sheet ---

  # The matchday card — both XIs, the benches, the absentees and the referee —
  # posted at most once per thread. Sofascore publishes lineups about an hour
  # before kickoff, so it is normally a pre-kickoff poll that catches them.
  #
  # Probable lineups are held back while the match hasn't started: they still
  # change, and a board that turns out wrong is worse than one that arrives a
  # little later. Once the match is live, what Sofascore has *is* what was
  # fielded, so it goes up whether or not the payload says "confirmed".
  #
  # A match that kicks off with no lineups published still gets a card with the
  # referee alone: coverage is often started at kickoff, and that is the last
  # moment the information is worth anything.
  #
  # The key is the thread's fixture id whichever provider supplied the lineups,
  # so a switch of data source mid-coverage doesn't post a second card.
  defp maybe_post_team_sheet(topic, fixture_id, live, live?) do
    key = team_sheet_key(fixture_id)

    if MapSet.member?(posted_event_keys(topic.id), key) do
      :ok
    else
      case fetch_lineups(live) do
        {:ok, lineups} ->
          if lineups["confirmed"] || live? do
            post_team_sheet(topic, live.event, lineups, key)
          else
            :ok
          end

        {:error, _reason} ->
          if live?, do: post_team_sheet(topic, live.event, nil, key), else: :ok
      end
    end
  end

  defp fetch_lineups(%{source: :sofascore, ref: event_id}), do: Sofascore.lineups(event_id)
  defp fetch_lineups(%{source: :fotmob, ref: match_id}), do: Colloq.FotMob.lineups(match_id)

  defp post_team_sheet(topic, event, lineups, key) do
    referee = Sofascore.referee(event)

    # Nothing to show: no lineups and no official listed. Skipping without
    # storing the key leaves the door open for a later poll.
    if is_nil(lineups) and is_nil(referee) do
      :ok
    else
      Forum.create_post(topic, get_or_create_scorebot_user(), %{
        "body" => team_sheet_body(event, lineups, referee),
        "is_system" => true,
        "system_type" => "lineups",
        "event_data" =>
          event
          |> Colloq.Sofascore.TeamSheet.build(lineups)
          |> Map.put("key", key)
      })

      Logger.info("[ResultaBot] formaciones publicadas en topic #{topic.id}")
      :ok
    end
  end

  defp team_sheet_key(fixture_id), do: "teamsheet:#{to_int(fixture_id)}"

  defp team_sheet_body(_event, nil, referee) do
    "🧑‍⚖️ <strong>Árbitro</strong> — dirige #{referee.name}. Sin formaciones publicadas todavía."
  end

  defp team_sheet_body(event, lineups, referee) do
    s = Sofascore.match_summary(event)
    label = if lineups["confirmed"], do: "Formaciones confirmadas", else: "Formaciones probables"
    ref = if referee, do: " · Árbitro: #{referee.name}", else: ""

    "👥 <strong>#{label}</strong> — #{s.home} vs #{s.away}#{ref}"
  end

  defp create_event_post(topic, event, source) do
    system_user = get_or_create_scorebot_user()

    {type_label, body} = render_event(event)

    Forum.create_post(topic, system_user, %{
      "body" => body,
      "is_system" => true,
      "system_type" => type_label,
      # The key is what already_posted?/3 reads back to skip this event on the
      # next poll; without it stored, dedup silently never matches. The source
      # lets it recognise the event if the other provider reports it later.
      "event_data" => event |> Map.put(:key, event_key(event)) |> Map.put(:source, to_string(source))
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
      # A substitution has player_in/player_out and no detail; reading the
      # fields strictly raised and killed the poll right after posting a sub.
      player: event[:player] || event[:player_in],
      minute: event.minute,
      detail: event[:detail],
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
    found =
      Colloq.DataSource.order(:standings)
      |> Enum.find_value(&racing_standings(&1, event))

    case found do
      {rows, season_id} ->
        svg = Colloq.Sofascore.StandingsSvg.render(rows)

        Forum.create_post(topic, get_or_create_scorebot_user(), %{
          "body" => "📊 Tabla de Posiciones — Liga Profesional",
          "is_system" => true,
          "system_type" => "standings",
          "event_data" => %{"season_id" => season_id, "svg" => svg}
        })

      nil ->
        :ok
    end
  end

  # Racing's group as `{rows, season_id}`, or nil when the provider can't say.
  defp racing_standings(:sofascore, event) do
    season_id = get_in(event, ["season", "id"]) || Sofascore.current_season_id()

    with true <- is_integer(season_id),
         {:ok, data} <- Sofascore.standings(season_id),
         rows when rows != [] <- standings_rows(data) do
      {rows, season_id}
    else
      _ -> nil
    end
  end

  # FotMob team ids aren't Sofascore's, so Racing's group is found by name.
  defp racing_standings(:fotmob, _event) do
    racing = Sofascore.team_info(:racing).name

    with {:ok, groups} <- Colloq.FotMob.liga_standings(),
         {_label, rows} <-
           Enum.find(groups, fn {_label, rows} ->
             Enum.any?(rows, &(get_in(&1, ["team", "name"]) == racing))
           end) do
      {rows, Sofascore.current_season_id()}
    else
      _ -> nil
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