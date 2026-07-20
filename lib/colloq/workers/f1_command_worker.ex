defmodule Colloq.Workers.F1CommandWorker do
  @moduledoc """
  Answers `/f1 <consulta>` commands, replying in-topic as FangioBot.

  Same shape as `SofascoreCommandWorker`: keyword routing, one answered query
  per user per 10 minutes, replies rendered as SVG system posts.

  Data comes from `Colloq.F1` (Jolpica). Replies state whether the numbers were
  served from cache, since standings are cached for 30 minutes and a table read
  minutes after a race finishes may not include it yet.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  require Logger

  alias Colloq.{Accounts, F1, Forum}
  alias Colloq.F1.Svg

  @rate_ttl :timer.minutes(10)
  @throttle_notice_ttl :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Forum.get_post!(post_id)
    query = extract_query(post.body)

    cond do
      is_nil(query) ->
        :ok

      rate_limited?(post.user_id) ->
        maybe_throttle_notice(post)
        :ok

      true ->
        post_reply(post, build_reply(query))
        Cachex.put(:forum_cache, rate_key(post.user_id), System.system_time(:second), ttl: @rate_ttl)
        :ok
    end
  end

  @doc """
  Strips HTML and the `/f1` prefix, returning the trimmed query (`""` when the
  command has no arguments, `nil` when the post isn't an `/f1` command).
  """
  def extract_query(body) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim()

    # One regex for both the test and the strip, with a word boundary: a bare
    # prefix check treated "/calendario" as "/ca" and returned the whole string
    # as the query.
    case Regex.run(~r/^\/f1\b(.*)/is, plain) do
      [_, rest] -> String.trim(rest)
      _ -> nil
    end
  end

  def extract_query(_), do: nil

  # --- Routing ---------------------------------------------------------------

  @doc false
  def build_reply(query) do
    # A 4-digit year anywhere in the query selects the season and is then
    # removed, so "/f1 verstappen 2023" still matches the driver by name.
    {year, query} = extract_year(query)
    norm = deaccent(String.downcase(query))

    # Spanish and English both, since the forum runs in Spanish but members
    # (and admins browsing with locale "en") reach for English words —
    # "/f1 drivers" used to fall through to the help text.
    cond do
      norm == "" and is_integer(year) ->
        drivers_reply(year)

      norm == "" ->
        next_race_reply()

      String.contains?(norm, ["constructor", "equipos", "escuderia", "escuderias", "teams"]) ->
        constructors_reply(year)

      # Before the results branch: "carreras" contains "carrera", so checking
      # results first made this calendar keyword unreachable.
      String.contains?(norm, [
        "calendario",
        "fixture",
        "temporada",
        "carreras",
        "calendar",
        "schedule",
        "upcoming",
        "season"
      ]) ->
        calendar_reply(year)

      String.contains?(norm, [
        "resultado",
        "carrera",
        "ultima",
        "gano",
        "podio",
        "result",
        "winner",
        "podium"
      ]) ->
        results_reply(year)

      # "tabla"/"campeonato" default to drivers, the table people mean.
      String.contains?(norm, [
        "tabla",
        "campeonato",
        "pilotos",
        "posiciones",
        "standings",
        "pilots",
        "drivers",
        "championship"
      ]) ->
        drivers_reply(year)

      String.contains?(norm, ["proxima", "proximo", "cuando", "siguiente", "next", "when"]) ->
        next_race_reply()

      # Anything left is treated as a driver name — "/f1 verstappen". Help is
      # the fallback only when that finds nobody.
      true ->
        driver_reply(query, year)
    end
  end

  # A single driver's season. Stats are derived from their race results:
  # Jolpica has no per-driver summary endpoint, and
  # `/drivers/{id}/driverStandings.json` comes back empty even for champions.
  defp driver_reply(query, year \\ nil) do
    case F1.find_driver(query, year) do
      {:ok, driver, _} ->
        case F1.driver_season(driver["driverId"], year) do
          {:ok, [], _} ->
            "<p>#{esc(driver["givenName"])} #{esc(driver["familyName"])} no corrió en #{year || F1.season()}.</p>"

          {:ok, rows, source} ->
            summary = F1.season_summary(rows)
            name = "#{driver["givenName"]} #{driver["familyName"]}"
            team = current_constructor(rows)

            svg =
              Svg.driver_card(driver, rows, summary,
                constructor_id: team["constructorId"],
                subtitle: [team["name"], driver["nationality"]] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
              )

            {:svg, "#{name} — #{year || F1.season()}", svg, source}

          _ ->
            error_text()
        end

      {:error, :not_found} ->
        help_text()

      _ ->
        error_text()
    end
  end

  # Pulls a 4-digit season out of the query and returns it with the year
  # removed. Bounded to real F1 seasons: 1950 is the first world championship,
  # and a future year has no data, so both are treated as "not a year" and left
  # in the text rather than silently returning an empty table.
  @first_season 1950
  defp extract_year(query) do
    case Regex.run(~r/\b(\d{4})\b/, query) do
      [match, digits] ->
        year = String.to_integer(digits)

        if year >= @first_season and year <= Date.utc_today().year do
          {year, query |> String.replace(match, "") |> String.trim()}
        else
          {nil, query}
        end

      _ ->
        {nil, query}
    end
  end

  # Team from the most recent race, so a mid-season move shows the current seat.
  defp current_constructor(rows) do
    rows
    |> List.last()
    |> case do
      %{result: %{"Constructor" => constructor}} when is_map(constructor) -> constructor
      _ -> %{}
    end
  end

  defp drivers_reply(year \\ nil) do
    case F1.driver_standings(year) do
      {:ok, [], _} -> "<p>No hay posiciones de pilotos para #{year || F1.season()}.</p>"
      {:ok, rows, source} -> {:svg, "Campeonato de Pilotos #{year || F1.season()}", Svg.driver_standings(rows), source}
      _ -> error_text()
    end
  end

  defp constructors_reply(year \\ nil) do
    case F1.constructor_standings(year) do
      {:ok, [], _} -> "<p>No hay posiciones de constructores para #{year || F1.season()}.</p>"
      {:ok, rows, source} -> {:svg, "Campeonato de Constructores #{year || F1.season()}", Svg.constructor_standings(rows), source}
      _ -> error_text()
    end
  end

  defp results_reply(year \\ nil) do
    case F1.last_results(year) do
      {:ok, race, source} ->
        {:svg, "#{race["raceName"]} — resultado", Svg.race_results(race), source}

      {:error, :no_results} ->
        "<p>Todavía no se corrió ninguna carrera esta temporada.</p>"

      _ ->
        error_text()
    end
  end

  defp calendar_reply(year \\ nil) do
    today = Date.to_iso8601(Date.utc_today())

    case F1.schedule(year) do
      {:ok, [], _} ->
        "<p>No pude obtener el calendario.</p>"

      {:ok, races, source} ->
        # Past rounds are dead weight in *this* season's calendar, but asking
        # for 2021 means asking for the whole 2021 calendar, not the empty tail
        # of it — so only filter when showing the current year.
        current? = is_nil(year) or year == F1.season()
        upcoming = if current?, do: Enum.filter(races, &(&1["date"] >= today)), else: races
        shown = if upcoming == [], do: races, else: upcoming
        {:svg, "Calendario F1 #{year || F1.season()}", Svg.calendar(shown), source}

      _ ->
        error_text()
    end
  end

  defp next_race_reply do
    case F1.next_race() do
      {:ok, race, source} ->
        {date, time} = F1.local_start(race)
        circuit = get_in(race, ["Circuit", "circuitName"]) || ""
        location = get_in(race, ["Circuit", "Location", "locality"]) || ""
        when_text = if time, do: "#{date} a las #{time}", else: date

        {:html, source,
         "<p>🏁 <strong>Próxima carrera: #{esc(race["raceName"])}</strong> (fecha #{esc(race["round"])})</p>" <>
           "<p>📍 #{esc(circuit)}, #{esc(location)}<br />🗓️ #{esc(when_text)} (hora de Argentina)</p>"}

      {:error, :season_over} ->
        "<p>La temporada terminó. Probá <code>/f1 tabla</code> para ver cómo quedó.</p>"

      _ ->
        error_text()
    end
  end

  defp help_text do
    """
    <p>🏎️ <strong>FangioBot</strong> — comandos:</p>
    <ul>
      <li><code>/f1</code> — próxima carrera</li>
      <li><code>/f1 pilotos</code> — campeonato de pilotos (o <code>tabla</code>)</li>
      <li><code>/f1 constructores</code> — campeonato de constructores</li>
      <li><code>/f1 resultado</code> — resultado de la última carrera</li>
      <li><code>/f1 calendario</code> — carreras que vienen</li>
    </ul>
    <p><em>También entiende inglés: <code>drivers</code>, <code>constructors</code>,
    <code>result</code>, <code>calendar</code>, <code>next</code>.</em></p>
    """
  end

  defp error_text, do: "<p>No pude obtener los datos de F1 ahora mismo. Probá de nuevo en un rato.</p>"

  # --- Reply plumbing --------------------------------------------------------

  defp post_reply(post, {:svg, title, svg, source}) do
    post_reply_attrs(post, %{
      "body" => "🏎️ #{esc(title)} · #{freshness(source)}",
      "is_system" => true,
      "system_type" => "standings",
      "event_data" => %{"svg" => svg, "title" => title, "cached" => source == :cached}
    })
  end

  defp post_reply(post, {:html, source, html}) do
    post_reply_attrs(post, %{"body" => html <> "<p><em>#{freshness(source)}</em></p>"})
  end

  defp post_reply(post, html) when is_binary(html) do
    post_reply_attrs(post, %{"body" => html})
  end

  defp freshness(:cached), do: "🗄️ cacheado"
  defp freshness(_), do: "🔄 recién actualizado"

  defp post_reply_attrs(post, attrs) do
    topic = Forum.get_topic!(post.topic_id)
    bot = get_or_create_bot()
    attrs = Map.put(attrs, "parent_id", post.id)

    case Forum.create_post(topic, bot, attrs) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} ->
        Logger.warning("[F1Command] could not reply in topic #{topic.id}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[F1Command] reply failed: #{inspect(error)}")
      :ok
  end

  defp get_or_create_bot do
    case Accounts.get_user_by_username("fangiobot") do
      nil ->
        {:ok, user} =
          Accounts.register_bot(%{
            email: "fangiobot@colloq.local",
            username: "fangiobot",
            display_name: "FangioBot",
            password: "fangiobot-internal",
            password_confirmation: "fangiobot-internal"
          })

        user

      user ->
        user
    end
  end

  # --- Rate limiting ---------------------------------------------------------

  defp rate_key(user_id), do: "f1_cmd:#{user_id}"

  defp rate_limited?(user_id) do
    match?({:ok, ts} when is_integer(ts), Cachex.get(:forum_cache, rate_key(user_id)))
  end

  defp maybe_throttle_notice(post) do
    notice_key = "f1_throttled:#{post.user_id}"

    case Cachex.get(:forum_cache, notice_key) do
      {:ok, nil} ->
        post_reply(post, "<p>⏳ Esperá unos minutos entre consultas de <code>/f1</code>.</p>")
        Cachex.put(:forum_cache, notice_key, true, ttl: @throttle_notice_ttl)

      _ ->
        :ok
    end
  end

  defp deaccent(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  defp esc(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
