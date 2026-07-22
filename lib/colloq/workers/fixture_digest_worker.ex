defmodule Colloq.Workers.FixtureDigestWorker do
  @moduledoc """
  Daily Liga Profesional fixture digest worker.

  9 AM BUE cron: fetches today's matches from Sofascore
  and posts a preview in the digest topic.

  11 PM BUE cron: fetches results and posts a summary.
  Re-enqueues +30 min if any matches are still in play.

  Posts the league standings after the last match of the round.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Forum.Topic
  alias Colloq.Accounts
  alias Colloq.SiteSettings

  require Logger

  # Fixtures here come from the Sofascore cache, so this must be a *Sofascore*
  # id. It was hardcoded to 174, which is Farsley Celtic (an English non-league
  # side) — verified against the API — so the ⭐ that marks Racing's match in
  # the digest never once appeared. Read from the registry rather than copied,
  # so it can't drift out of sync again.
  defp racing_id, do: Colloq.Sofascore.racing_team_id()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "preview"} = args}) do
    digest_topic = get_digest_topic()
    fixtures = get_fixtures_from_cache()

    if fixtures == [] do
      {:discard, "sin fixtures en caché"}
    else
      today_fixtures = filter_today(fixtures)
      publish_preview(digest_topic, today_fixtures)

      schedule_result_fetch(args)
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "summary"} = args}) do
    digest_topic = get_digest_topic()
    fixtures = get_fixtures_from_cache()

    if fixtures == [] do
      {:discard, "sin fixtures en caché"}
    else
      today_fixtures = filter_today(fixtures)
      {finished, in_progress} = partition_by_status(today_fixtures)

      if finished != [] do
        publish_summary(digest_topic, finished)
      end

      if in_progress != [] do
        Logger.info("[FixtureDigest] #{length(in_progress)} partidos en juego, reprogramando +30min")
        reschedule_self(args, 30)
      end

      maybe_publish_standings(today_fixtures, digest_topic)

      :ok
    end
  end

  defp get_digest_topic do
    topic_id = SiteSettings.get("fixture_digest_topic_id")

    if topic_id do
      Repo.get!(Topic, topic_id)
    else
      Logger.warning("[FixtureDigest] fixture_digest_topic_id no configurado")
      nil
    end
  end

  defp get_fixtures_from_cache do
    case Cachex.get(:forum_cache, "sofascore:fixtures") do
      {:ok, nil} -> []
      {:ok, fixtures} -> fixtures
      {:error, _} -> []
    end
  end

  defp filter_today(fixtures) do
    # Date.utc_to_local_date/2 does not exist — this raised on every run, so
    # filter_today/1 never returned and the digest never published.
    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!("America/Argentina/Buenos_Aires")
      |> DateTime.to_date()

    Enum.filter(fixtures, fn f ->
      event_date = f["startDate"]
      event_date && date_from_sofascore(event_date) == today
    end)
  end

  defp date_from_sofascore(nil), do: nil
  defp date_from_sofascore(timestamp) do
    timestamp
    |> DateTime.from_unix!(:second)
    |> DateTime.shift_zone!("America/Argentina/Buenos_Aires")
    |> DateTime.to_date()
  end

  defp partition_by_status(fixtures) do
    Enum.split_with(fixtures, fn f ->
      f["status"]["type"] in ["finished", "cancelled", "postponed"]
    end)
  end

  defp publish_preview(topic, fixtures) do
    if is_nil(topic) or fixtures == [] do
      :ok
    else
      system_user = find_system_user()
      body = build_preview_body(fixtures)

      Forum.create_post(topic, system_user, %{
        "body" => body,
        "is_system" => true,
        "system_type" => "fixture_preview",
        "event_data" => %{fixture_count: length(fixtures)}
      })

      Logger.info("[FixtureDigest] Preview publicada: #{length(fixtures)} partidos")
    end
  end

  defp publish_summary(topic, fixtures) do
    if is_nil(topic) or fixtures == [] do
      :ok
    else
      system_user = find_system_user()
      body = build_summary_body(fixtures)

      Forum.create_post(topic, system_user, %{
        "body" => body,
        "is_system" => true,
        "system_type" => "fixture_summary",
        "event_data" => %{fixture_count: length(fixtures)}
      })

      Logger.info("[FixtureDigest] Resumen publicado: #{length(fixtures)} resultados")
    end
  end

  defp build_preview_body(fixtures) do
    lines =
      Enum.map(fixtures, fn f ->
        home = f["homeTeam"]["name"]
        away = f["awayTeam"]["name"]
        time = format_time(f["startDate"])
        is_racing = f["homeTeam"]["id"] == racing_id() || f["awayTeam"]["id"] == racing_id()
        prefix = if is_racing, do: "⭐ ", else: ""

        "#{prefix}**#{home}** vs **#{away}** — #{time}"
      end)

    """
    <h2>📅 Partidos de Hoy — Liga Profesional</h2>
    #{Enum.join(lines, "\n")}
    <p><em>Seguí el minuto a minuto en los hilos de partido.</em></p>
    """
  end

  defp build_summary_body(fixtures) do
    lines =
      Enum.map(fixtures, fn f ->
        home = f["homeTeam"]["name"]
        away = f["awayTeam"]["name"]
        home_score = f["homeScore"]["current"] || 0
        away_score = f["awayScore"]["current"] || 0
        is_racing = f["homeTeam"]["id"] == racing_id() || f["awayTeam"]["id"] == racing_id()

        if is_racing do
          "⭐ <span style=\"color: #22c55e; font-weight: bold;\">#{home} #{home_score} - #{away_score} #{away}</span>"
        else
          "**#{home}** #{home_score} - #{away_score} **#{away}**"
        end
      end)

    """
    <h2>🏁 Resultados de Hoy — Liga Profesional</h2>
    #{Enum.join(lines, "\n")}
    """
  end

  defp maybe_publish_standings(fixtures, topic) do
    if is_nil(topic) do
      :ok
    else
      all_finished? = Enum.all?(fixtures, fn f ->
        f["status"]["type"] in ["finished", "cancelled", "postponed"]
      end)

      if all_finished? and fixtures != [] do
        season_id = get_season_id_from_fixtures(fixtures)

        if season_id do
          publish_standings(topic, season_id)
        end
      end
    end
  end

  defp publish_standings(topic, season_id) do
    with {:ok, standings} when not is_nil(standings) <-
           Cachex.get(:forum_cache, "sofascore:standings:#{season_id}"),
         rows when rows != [] <- standings_rows(standings) do
      svg = Colloq.Sofascore.StandingsSvg.render(rows)

      Forum.create_post(topic, find_system_user(), %{
        # The SVG carries the whole table; the body is just a caption for
        # notifications, previews and summaries.
        "body" => "📊 Tabla de Posiciones — Liga Profesional",
        "is_system" => true,
        "system_type" => "standings",
        "event_data" => %{"season_id" => season_id, "svg" => svg}
      })
    else
      _ -> :ok
    end
  end

  # The cached payload is the /standings/total response: a "standings" array of
  # tables, each with "rows". Fall back to a bare "rows" for older shapes.
  defp standings_rows(%{"standings" => tables}) when is_list(tables),
    do: Enum.flat_map(tables, &Map.get(&1, "rows", []))

  defp standings_rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp standings_rows(_), do: []

  defp format_time(nil), do: "--:--"
  defp format_time(timestamp) do
    timestamp
    |> DateTime.from_unix!(:second)
    |> DateTime.shift_zone!("America/Argentina/Buenos_Aires")
    |> Calendar.strftime("%H:%M")
  end

  defp get_season_id_from_fixtures([first | _]) do
    first["season"]["id"]
  rescue
    _ -> nil
  end
  defp get_season_id_from_fixtures([]), do: nil

  defp reschedule_self(args, minutes_after) do
    scheduled_at = DateTime.utc_now() |> DateTime.add(minutes_after, :minute)

    args
    |> Map.put("action", "summary")
    |> Colloq.Workers.FixtureDigestWorker.new(scheduled_at: scheduled_at)
    |> Oban.insert()
  end

  defp schedule_result_fetch(args) do
    # Oban's schedule_in is in *seconds*; :timer.hours/1 returns milliseconds,
    # which scheduled the summary ~1.6 years out instead of 14 hours.
    %{args | "action" => "summary"}
    |> Colloq.Workers.FixtureDigestWorker.new(schedule_in: {14, :hours})
    |> Oban.insert()
  end

  defp find_system_user do
    case Accounts.get_user_by_username("scorebot") do
      nil -> Accounts.get_user!(1)
      user -> user
    end
  end
end
