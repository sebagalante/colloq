defmodule Colloq.Workers.SofascoreCommandWorker do
  @moduledoc """
  Answers `/sofascore <consulta>` commands posted in a topic.

  Triggered on post creation when the body starts with `/sofascore`. Parses the
  query with simple keyword routing (fixtures, standings, squad, player) and
  replies **in the same topic** as the `sofascorebot` system user.

  Rate limited to one answered query per user per 10 minutes.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  require Logger

  alias Colloq.{Forum, Sofascore, Accounts}

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
        reply = build_reply(query)
        post_reply(post, reply)
        Cachex.put(:forum_cache, rate_key(post.user_id), System.system_time(:second), ttl: @rate_ttl)
        :ok
    end
  end

  # --- Command parsing -------------------------------------------------------

  @doc """
  Strips HTML (posts are Tiptap HTML) and the `/sofascore` prefix, returning
  the trimmed query (`""` when the command has no arguments, `nil` otherwise).
  """
  def extract_query(body) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim()

    if plain |> String.downcase() |> String.starts_with?("/sofascore") do
      plain
      |> String.replace(~r/^\/sofascore\b/i, "")
      |> String.trim()
    else
      nil
    end
  end

  def extract_query(_), do: nil

  # --- Routing ---------------------------------------------------------------

  def build_reply(""), do: help_text()

  def build_reply(query) do
    norm = deaccent(String.downcase(query))

    cond do
      # "comparar X vs Y" — head-to-head player comparison rendered as an SVG.
      # Checked first so "comparar" never falls through to the player branch.
      String.contains?(norm, ["comparar", "compara", "comparacion", " vs ", " versus "]) ->
        comparison_reply(query)

      # "tabla anual" / "anual" → year-long cumulative table; plain "tabla" → torneo.
      String.contains?(norm, "anual") ->
        annual_standings_reply()

      String.contains?(norm, ["tabla", "posicion", "posiciones", "puesto"]) ->
        standings_reply()

      # Before the "resultado"/"anterior" branch: "resultados de la fecha" is a
      # request for the round, not for Racing's last match, and "resultado" used
      # to win that collision and answer the wrong question entirely.
      String.contains?(norm, ["liga", "fecha", "jornada", "ronda"]) ->
        liga_reply(parse_round(norm))

      # Check "anterior" before the general "partido" branch — "partido anterior"
      # matches both, and the last result is the more specific intent.
      String.contains?(norm, ["anterior", "ultimo", "pasado", "resultado"]) ->
        last_match_reply()

      String.contains?(norm, ["proximo", "partido", "fixture", "cuando juega", "rival"]) ->
        fixture_reply()

      String.contains?(norm, ["plantel", "plantilla", "jugadores", "squad", "equipo actual"]) ->
        squad_reply()

      true ->
        player_reply(query)
    end
  end

  # First number in the query is the round. Without one, use the round Racing is
  # actually playing — this defaulted to fecha 1, so a bare "fecha liga" in July
  # answered with January's matchday.
  defp parse_round(norm) do
    case Regex.run(~r/\d+/, norm) do
      [n] -> String.to_integer(n)
      _ -> current_round()
    end
  end

  defp current_round do
    case Sofascore.relevant_match(Sofascore.racing_team_id()) do
      {:ok, event} -> get_in(event, ["roundInfo", "round"]) || 1
      _ -> 1
    end
  end

  # --- Next fixture ----------------------------------------------------------

  defp fixture_reply do
    case Sofascore.relevant_match(Sofascore.racing_team_id()) do
      {:ok, event} -> fixture_card(event)
      _ -> "<p>No pude obtener el partido ahora mismo. Probá de nuevo en un rato.</p>"
    end
  end

  defp last_match_reply do
    case Sofascore.last_finished_match(Sofascore.racing_team_id()) do
      {:ok, event} -> fixture_card(event)
      _ -> "<p>No pude obtener el partido anterior ahora mismo. Probá de nuevo en un rato.</p>"
    end
  end

  # --- League round (todos los partidos de una fecha) ------------------------

  defp liga_reply(round) do
    case Sofascore.round_fixtures_cached(round) do
      {:ok, [], _source} ->
        "<p>No hay partidos para la fecha #{round}.</p>"

      {:ok, events, source} ->
        # Both halves of the season share round numbers, so a round can carry a
        # matchday from months ago alongside the current one. Keep the current.
        case Sofascore.current_phase(events) do
          [] -> "<p>No hay partidos para la fecha #{round}.</p>"
          phase -> {:round, round, phase, source}
        end

      {:error, :no_season} ->
        "<p>La liga no está configurada todavía (falta el id de temporada). Pediselo a un admin.</p>"

      _ ->
        "<p>No pude obtener la fecha #{round} ahora mismo. Probá de nuevo en un rato.</p>"
    end
  end

  # A match card, rendered as HTML (post bodies are HTML, not markdown). Kept to
  # what the write-time sanitizer (basic_html) allows: table / img / strong / p —
  # no class or style survive, so the "card" look comes from crest images and
  # shields.io badges rather than CSS. Team names below the crests keep it
  # readable even if a crest image fails to load.
  defp fixture_card(event) do
    home = get_in(event, ["homeTeam", "name"]) || "?"
    away = get_in(event, ["awayTeam", "name"]) || "?"
    home_id = get_in(event, ["homeTeam", "id"])
    away_id = get_in(event, ["awayTeam", "id"])

    tournament =
      get_in(event, ["tournament", "name"]) ||
        get_in(event, ["tournament", "uniqueTournament", "name"])

    when_str = fixture_datetime(event["startTimestamp"])
    state = get_in(event, ["status", "type"])
    center = center_badge(event, state)

    """
    #{status_line(event, state)}<table><tbody>
    <tr>#{crest_cell(home_id, home)}<td><img src="#{center}" alt="#{esc(center_alt(event, state))}" /></td>#{crest_cell(away_id, away)}</tr>
    <tr><td><strong>#{esc(home)}</strong></td><td></td><td><strong>#{esc(away)}</strong></td></tr>
    </tbody></table>
    #{scorers(event, state)}<p>#{meta_line(when_str, tournament)}</p>
    """
  end

  # Goalscorers, home group then away, only once the match is live/finished
  # (incidents don't exist before kickoff). "(p)" = penalty, "(ec)" = en contra.
  defp scorers(event, state) when state in ["inprogress", "finished"] do
    case Sofascore.goals(event["id"]) do
      [] ->
        ""

      goals ->
        {home, away} = Enum.split_with(goals, & &1.home?)

        segments =
          [format_goals(home), format_goals(away)]
          |> Enum.reject(&(&1 == ""))

        case segments do
          [] -> ""
          segs -> "<p>⚽ #{Enum.join(segs, " · ")}</p>\n"
        end
    end
  end

  defp scorers(_event, _state), do: ""

  defp format_goals(goals) do
    goals
    |> Enum.map(fn g -> "#{esc(g.name)} #{g.minute}'#{goal_suffix(g.kind)}" end)
    |> Enum.join(", ")
  end

  defp goal_suffix("penalty"), do: " (p)"
  defp goal_suffix("ownGoal"), do: " (ec)"
  defp goal_suffix(_), do: ""

  # A state banner above the card: live (with the running clock), or a finished
  # marker. Upcoming needs no banner — its kickoff time is the centre badge.
  defp status_line(event, "inprogress"),
    do: "<p>🔴 <strong>EN VIVO</strong> · #{esc(live_clock(event))}</p>\n"

  defp status_line(_event, "finished"), do: "<p>⏹️ <strong>Finalizado</strong></p>\n"
  defp status_line(_event, _), do: ""

  # Best-effort live minute from Sofascore's period clock. `status.description`
  # is English regardless of locale ("1st half", "2nd half", "Halftime", …).
  defp live_clock(event) do
    desc = get_in(event, ["status", "description"]) || ""
    start = get_in(event, ["time", "currentPeriodStartTimestamp"])

    cond do
      String.contains?(desc, "Halftime") -> "Entretiempo"
      String.contains?(desc, "Penalt") -> "Penales"
      String.contains?(desc, "Extra") and is_integer(start) -> minute_from(start, 90)
      String.contains?(desc, "2nd") and is_integer(start) -> minute_from(start, 45)
      String.contains?(desc, "1st") and is_integer(start) -> minute_from(start, 0)
      true -> "En juego"
    end
  end

  defp minute_from(start, base) do
    elapsed = div(max(System.system_time(:second) - start, 0), 60)
    "#{base + elapsed + 1}'"
  end

  defp crest_cell(nil, _name), do: "<td></td>"

  defp crest_cell(id, name),
    do: ~s(<td><img src="#{crest(id)}" width="56" height="56" alt="#{esc(name)}" /></td>)

  defp crest(id), do: "https://api.sofascore.com/api/v1/team/#{id}/image"

  # Centre badge: the score while live (red) or finished (slate), else the
  # kickoff time. en dash (not "-") avoids clashing with shields' separator.
  defp center_badge(event, "inprogress"), do: score_badge(event, "c1272d") || time_badge(event)
  defp center_badge(event, "finished"), do: score_badge(event, "475569") || time_badge(event)
  defp center_badge(event, _), do: time_badge(event)

  defp score_badge(event, color) do
    case {get_in(event, ["homeScore", "current"]), get_in(event, ["awayScore", "current"])} do
      {h, a} when is_integer(h) and is_integer(a) -> badge_url("#{h} – #{a}", color)
      _ -> nil
    end
  end

  defp time_badge(event), do: badge_url(fixture_time(event["startTimestamp"]) || "VS", "1f2a44")

  defp center_alt(event, state) when state in ["inprogress", "finished"] do
    case {get_in(event, ["homeScore", "current"]), get_in(event, ["awayScore", "current"])} do
      {h, a} when is_integer(h) and is_integer(a) -> "#{h} - #{a}"
      _ -> fixture_time(event["startTimestamp"]) || "VS"
    end
  end

  defp center_alt(event, _), do: fixture_time(event["startTimestamp"]) || "VS"

  defp meta_line(when_str, tournament) do
    [
      when_str && "🗓️ #{esc(when_str)} (hora Argentina)",
      tournament && "🏆 #{esc(tournament)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp badge_url(text, color) do
    enc = URI.encode(text, &URI.char_unreserved?/1)
    "https://img.shields.io/badge/#{enc}-#{color}?style=for-the-badge"
  end

  defp fixture_time(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!() |> DateTime.add(-3 * 3600, :second) |> Calendar.strftime("%H:%M")
  end

  defp fixture_time(_), do: nil

  defp esc(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp fixture_datetime(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!()
    # Argentina is UTC-3 year-round (no DST).
    |> DateTime.add(-3 * 3600, :second)
    |> Calendar.strftime("%d/%m/%Y %H:%M")
  end

  defp fixture_datetime(_), do: nil

  # --- Standings -------------------------------------------------------------

  defp standings_reply do
    case Sofascore.current_season_id() do
      nil ->
        "<p>La tabla no está configurada todavía (falta el id de temporada). Pediselo a un admin.</p>"

      season_id ->
        case Sofascore.standings(season_id) do
          {:ok, data} -> format_standings(data, "Tabla — Liga Profesional", :torneo)
          _ -> "<p>No pude obtener la tabla ahora mismo. Probá de nuevo en un rato.</p>"
        end
    end
  end

  defp annual_standings_reply do
    case Sofascore.annual_standings() do
      {:ok, data} ->
        format_standings(data, "Tabla Anual — Liga Profesional", :annual)

      {:error, :no_annual} ->
        "<p>La tabla anual no está configurada todavía. Un admin puede cargar el id de la temporada anual.</p>"

      _ ->
        "<p>No pude obtener la tabla anual ahora mismo. Probá de nuevo en un rato.</p>"
    end
  end

  defp format_standings(data, title, which) do
    tables = data |> Map.get("standings", []) |> List.wrap()

    case pick_rows(tables, which) do
      {:ok, []} ->
        "<p>No hay datos de tabla disponibles.</p>"

      # Tagged so post_reply/2 renders it as an SVG system post instead of an
      # HTML table (see standings_svg + the standings_table component).
      {:ok, rows} ->
        {:standings, title, rows}

      # Couldn't find an annual-labelled table — surface which ones exist so we
      # can see exactly how Sofascore names it and match on that.
      {:not_found, tables} ->
        names = tables |> Enum.map_join(", ", &esc(&1["name"] || "?"))
        "<p>No encontré una tabla anual en la respuesta. Tablas disponibles: <em>#{names}</em>.</p>"
    end
  end

  # Annual → the table whose name looks annual/cumulative; anything else → all
  # rows (single-table torneo behaviour, unchanged).
  defp pick_rows(tables, :annual) do
    case Enum.find(tables, &annual_table?/1) do
      nil -> {:not_found, tables}
      table -> {:ok, Map.get(table, "rows", [])}
    end
  end

  defp pick_rows(tables, _), do: {:ok, Enum.flat_map(tables, &Map.get(&1, "rows", []))}

  defp annual_table?(table) do
    (table["name"] || "")
    |> String.downcase()
    |> String.contains?(["anual", "annual", "acumulad", "general"])
  end

  # --- Squad -----------------------------------------------------------------

  defp squad_reply do
    case Sofascore.list_or_fetch_squad(Sofascore.racing_team_id()) do
      [] ->
        "<p>Todavía no tengo el plantel cargado. Un admin puede actualizarlo desde el panel de Sofascore.</p>"

      players ->
        by_pos =
          Enum.group_by(players, &(&1.position || "Otros"))

        order = ["Arquero", "Defensor", "Mediocampista", "Delantero", "Otros"]

        body =
          order
          |> Enum.filter(&Map.has_key?(by_pos, &1))
          |> Enum.map_join("", fn pos ->
            names = by_pos[pos] |> Enum.map_join(", ", &esc(&1.name))
            "<p><strong>#{plural_position(pos)}:</strong> #{names}</p>"
          end)

        "<p>👥 <strong>Plantel de Racing</strong> (#{length(players)} jugadores)</p>#{body}"
    end
  end

  defp plural_position("Arquero"), do: "Arqueros"
  defp plural_position("Defensor"), do: "Defensores"
  defp plural_position("Mediocampista"), do: "Mediocampistas"
  defp plural_position("Delantero"), do: "Delanteros"
  defp plural_position(other), do: other

  # --- Player ----------------------------------------------------------------

  defp player_reply(query) do
    {clean, year} = extract_year(query)

    clean =
      clean
      |> String.replace(~r/\b(estadisticas|estadísticas|stats|jugador|de|del)\b/iu, "")
      |> String.trim()

    case Sofascore.search(clean) do
      [] ->
        "<p>No encontré ningún jugador con «#{esc(clean)}».</p>" <> help_text()

      [player | _] ->
        # A specific year → single-season card; otherwise the full career table.
        # Falls back to a text line if the stats API is unreachable.
        result =
          if year do
            with {:ok, card} <- Sofascore.player_card(player, year: year), do: {:player_card, card}
          else
            with {:ok, career} when career.rows != [] <- Sofascore.player_career(player),
                 do: {:player_career, career}
          end

        case result do
          {:player_card, _} = r -> r
          {:player_career, _} = r -> r
          _ -> "<p>👤 <strong>#{esc(player.name)}</strong>#{pos_suffix(player)}</p>" <> (player_stats_line(player) || "")
        end
    end
  end

  # Pull a trailing 4-digit year (or 2-digit "24/25"-style) out of the query so
  # `/sofascore jugador Messi 2023` selects that season. Returns {rest, year|nil}.
  defp extract_year(query) do
    case Regex.run(~r/\b((?:19|20)\d{2})\b\s*$/, query) do
      [_, year] -> {String.replace(query, ~r/\b(?:19|20)\d{2}\b\s*$/, "") |> String.trim(), year}
      _ -> {query, nil}
    end
  end


  defp pos_suffix(%{position: pos}) when is_binary(pos) and pos != "", do: " — #{esc(pos)}"
  defp pos_suffix(_), do: ""

  defp player_stats_line(player) do
    with season when is_integer(season) <- Sofascore.current_season_id(),
         {id, _} <- Integer.parse(to_string(player.sofascore_id)),
         {:ok, data} <- Sofascore.player_stats(id, season) do
      s = Map.get(data, "statistics", %{})
      goals = s["goals"] || 0
      apps = s["appearances"] || s["matchesPlayed"] || 0
      assists = s["assists"] || 0
      "<p>📈 Temporada: #{goals} goles, #{assists} asistencias en #{apps} partidos</p>"
    else
      _ -> nil
    end
  end

  # --- Comparison ------------------------------------------------------------

  # "comparar <a> vs <b>" — resolve both names, fetch season stats, and hand a
  # tagged tuple to post_reply/2 which renders it as an SVG system post.
  defp comparison_reply(query) do
    case parse_two_players(query) do
      {:error, :syntax} ->
        comparison_help()

      {name_a, name_b} ->
        case {Sofascore.search(name_a), Sofascore.search(name_b)} do
          {[a | _], [b | _]} ->
            season = Sofascore.current_season_id()

            {:comparison,
             %{name: a.name, id: a.sofascore_id, stats: season_stats(a, season)},
             %{name: b.name, id: b.sofascore_id, stats: season_stats(b, season)}}

          {[], _} ->
            "<p>No encontré ningún jugador con «#{esc(name_a)}».</p>"

          {_, []} ->
            "<p>No encontré ningún jugador con «#{esc(name_b)}».</p>"
        end
    end
  end

  # Strip the "comparar"/"comparación" verb, then split on the vs/versus/slash
  # separator into two trimmed names.
  defp parse_two_players(query) do
    cleaned =
      query
      |> String.replace(~r/\b(comparar|compara|comparaci[oó]n|jugadores?)\b/iu, "")
      |> String.trim()

    parts =
      cleaned
      |> String.split(~r/\s+(?:vs\.?|versus|contra)\s+|\s*\/\s*/iu, parts: 2)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case parts do
      [a, b] -> {a, b}
      _ -> {:error, :syntax}
    end
  end

  defp season_stats(player, season) do
    with s when is_integer(s) <- season,
         {id, _} <- Integer.parse(to_string(player.sofascore_id)),
         {:ok, data} <- Sofascore.player_stats(id, s) do
      Map.get(data, "statistics", %{})
    else
      _ -> %{}
    end
  end

  defp comparison_help do
    "<p>Para comparar dos jugadores usá: <code>/sofascore comparar Messi vs Suárez</code></p>"
  end

  # --- Reply plumbing --------------------------------------------------------

  # Standings render as an SVG system post: the table lives in event_data (the
  # body is only a caption), and the standings_table component draws it.
  defp post_reply(post, {:standings, title, rows}) do
    svg = Colloq.Sofascore.StandingsSvg.render(rows)

    post_reply_attrs(post, %{
      "body" => "📊 #{title}",
      "is_system" => true,
      "system_type" => "standings",
      "event_data" => %{"svg" => svg, "title" => title}
    })
  end

  # A league round renders as an SVG system post, same plumbing as standings.
  # The caption states whether the data came from the 10-minute cache, so a
  # score that looks stale during a live match is explainable rather than
  # mysterious.
  defp post_reply(post, {:round, round, events, source}) do
    title = "Liga Profesional — Fecha #{round}"
    svg = Colloq.Sofascore.RoundSvg.render(events, title: title)

    freshness =
      case source do
        :cached -> "🗄️ cacheado (hasta 10 min)"
        _ -> "🔄 recién actualizado"
      end

    post_reply_attrs(post, %{
      "body" => "⚽ #{esc(title)} · #{freshness}",
      "is_system" => true,
      "system_type" => "standings",
      "event_data" => %{"svg" => svg, "title" => title, "cached" => source == :cached}
    })
  end

  # Player comparison renders as an SVG system post, same plumbing as standings:
  # the SVG lives in event_data and the standings_table component draws it.
  defp post_reply(post, {:comparison, a, b}) do
    svg = Colloq.Sofascore.ComparisonSvg.render(a, b)
    title = "#{a.name} vs #{b.name}"

    post_reply_attrs(post, %{
      "body" => "🆚 #{esc(title)}",
      "is_system" => true,
      "system_type" => "comparison",
      "event_data" => %{"svg" => svg, "title" => title}
    })
  end

  # Single-player season card — same SVG-in-event_data plumbing as above.
  defp post_reply(post, {:player_card, card}) do
    svg = Colloq.Sofascore.PlayerCardSvg.render(card)
    title = "#{card.name} · #{card.season_label}"

    post_reply_attrs(post, %{
      "body" => "👤 #{esc(title)}",
      "is_system" => true,
      "system_type" => "player_card",
      "event_data" => %{"svg" => svg, "title" => title}
    })
  end

  # Full career table (all seasons) — same SVG-in-event_data plumbing.
  defp post_reply(post, {:player_career, career}) do
    svg = Colloq.Sofascore.CareerSvg.render(career)

    post_reply_attrs(post, %{
      "body" => "👤 #{esc(career.name)}",
      "is_system" => true,
      "system_type" => "player_card",
      "event_data" => %{"svg" => svg, "title" => career.name}
    })
  end

  defp post_reply(post, body) when is_binary(body) do
    post_reply_attrs(post, %{"body" => body})
  end

  defp post_reply_attrs(post, attrs) do
    topic = Forum.get_topic!(post.topic_id)
    bot = get_or_create_bot()
    attrs = Map.put(attrs, "parent_id", post.id)

    # create_post/3 returns an error *tuple* (not a raise) when the topic is
    # closed/archived/announcement — the bot isn't staff, so it can't post
    # there. The `rescue` below only catches exceptions, so without this the
    # bot would fail completely silently.
    case Forum.create_post(topic, bot, attrs) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} ->
        Logger.warning(
          "[SofascoreCommand] could not reply in topic #{topic.id} (closed=#{topic.closed} " <>
            "archived=#{topic.archived} staff_only=#{topic.staff_only}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e -> Logger.error("[SofascoreCommand] reply failed: #{inspect(e)}")
  end

  defp help_text do
    """
    <p>🤖 <strong>SofascoreBot</strong> — probá con:</p>
    <ul>
    <li><code>/sofascore partido</code> (en vivo o próximo)</li>
    <li><code>/sofascore partido anterior</code> (último resultado)</li>
    <li><code>/sofascore liga [fecha]</code> (fixture de una fecha)</li>
    <li><code>/sofascore tabla</code></li>
    <li><code>/sofascore tabla anual</code></li>
    <li><code>/sofascore plantel</code></li>
    <li><code>/sofascore comparar &lt;jugador&gt; vs &lt;jugador&gt;</code></li>
    <li><code>/sofascore &lt;nombre de jugador&gt;</code></li>
    </ul>
    """
  end

  # --- Rate limiting ---------------------------------------------------------

  defp rate_key(user_id), do: "sofascore_cmd:#{user_id}"

  defp rate_limited?(user_id) do
    match?({:ok, ts} when is_integer(ts), Cachex.get(:forum_cache, rate_key(user_id)))
  end

  # Post a single "wait" notice, deduped so repeated spamming stays quiet.
  defp maybe_throttle_notice(post) do
    notice_key = "sofascore_throttled:#{post.user_id}"

    case Cachex.get(:forum_cache, notice_key) do
      {:ok, nil} ->
        remaining = remaining_minutes(post.user_id)
        post_reply(post, "<p>⏳ Esperá ~#{remaining} min entre consultas de <code>/sofascore</code>.</p>")
        Cachex.put(:forum_cache, notice_key, true, ttl: @throttle_notice_ttl)

      _ ->
        :ok
    end
  end

  defp remaining_minutes(user_id) do
    case Cachex.get(:forum_cache, rate_key(user_id)) do
      {:ok, ts} when is_integer(ts) ->
        elapsed = System.system_time(:second) - ts
        max(1, div(600 - elapsed, 60) + 1)

      _ ->
        10
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp deaccent(str) do
    str
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  defp get_or_create_bot do
    case Accounts.get_user_by_username("sofascorebot") do
      nil ->
        {:ok, user} =
          Accounts.register_bot(%{
            email: "sofascorebot@colloq.local",
            username: "sofascorebot",
            display_name: "SofascoreBot",
            password: "sofascorebot-internal",
            password_confirmation: "sofascorebot-internal"
          })

        user

      user ->
        user
    end
  end
end
