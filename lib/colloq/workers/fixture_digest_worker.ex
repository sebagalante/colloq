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

  @racing_id 174

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
    today = Date.utc_to_local_date(DateTime.utc_now(), "America/Argentina/Buenos_Aires")

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
        is_racing = f["homeTeam"]["id"] == @racing_id || f["awayTeam"]["id"] == @racing_id
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
        is_racing = f["homeTeam"]["id"] == @racing_id || f["awayTeam"]["id"] == @racing_id

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
    case Cachex.get(:forum_cache, "sofascore:standings:#{season_id}") do
      {:ok, standings} when not is_nil(standings) ->
        system_user = find_system_user()
        table = format_standings_table(standings)

        body = """
        <h2>📊 Tabla de Posiciones — Liga Profesional</h2>
        #{table}
        """

        Forum.create_post(topic, system_user, %{
          "body" => body,
          "is_system" => true,
          "system_type" => "standings",
          "event_data" => %{season_id: season_id}
        })

      _ ->
        :ok
    end
  end

  defp format_standings_table(standings) do
    rows = standings["rows"] || []

    Enum.map_join(rows, "\n", fn row ->
      pos = row["position"]
      team = row["team"]["name"]
      pts = row["points"]
      pj = row["played"]
      gf = row["scoresFor"]
      gc = row["scoresAgainst"]
      gd = row["scoresDiff"]

      bold = if team_name?(team, "Racing"), do: "<strong>", else: ""
      bold_end = if team_name?(team, "Racing"), do: "</strong>", else: ""

      "#{pos}. #{bold}#{team}#{bold_end} — #{pts} pts (#{pj} PJ, +#{gf} -#{gc} DG:#{gd})"
    end)
  end

  defp team_name?(name, search), do: String.contains?(String.downcase(name), String.downcase(search))

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
    %{args | "action" => "summary"}
    |> Colloq.Workers.FixtureDigestWorker.new(schedule_in: :timer.hours(14))
    |> Oban.insert()
  end

  defp find_system_user do
    case Accounts.get_user_by_username("scorebot") do
      nil -> Accounts.get_user!(1)
      user -> user
    end
  end
end
