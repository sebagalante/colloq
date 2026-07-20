defmodule Colloq.F1.Svg do
  @moduledoc """
  Renders F1 replies as self-contained SVG strings.

  Same ground, rule colour and type scale as `Colloq.Sofascore.StandingsSvg` and
  `RoundSvg`, so a FangioBot reply sits next to a sofascorebot one without
  looking like a different product.

  Constructor colours come from a small hand-kept map: Jolpica exposes no team
  colour, and a championship table where every row is the same grey loses the
  one thing that makes an F1 standing scannable.
  """

  @width 720
  @header_h 38
  @row_h 32

  @bg "#0e1621"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @highlight_bg "#1b2431"

  # Keyed on Jolpica's constructorId.
  @team_colors %{
    "mercedes" => "#27F4D2",
    "ferrari" => "#E8002D",
    "red_bull" => "#3671C6",
    "mclaren" => "#FF8000",
    "aston_martin" => "#229971",
    "alpine" => "#00A1E8",
    "williams" => "#1868DB",
    "rb" => "#6692FF",
    "sauber" => "#01C00E",
    "haas" => "#9C9FA2",
    "audi" => "#00E701",
    "cadillac" => "#B6862C"
  }

  @default_color "#8a94a6"

  @doc "Drivers' championship table."
  def driver_standings(rows, opts \\ []) do
    title = Keyword.get(opts, :title, "Campeonato de Pilotos")

    body =
      rows
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {row, i} ->
        team = List.first(row["Constructors"] || []) || %{}
        driver = row["Driver"] || %{}

        name =
          [driver["givenName"], driver["familyName"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        standing_row(
          @header_h + i * @row_h,
          row["position"],
          name,
          team["name"],
          team["constructorId"],
          row["points"],
          wins_label(row["wins"])
        )
      end)

    wrap(title, "Pts", body, @header_h + max(length(rows), 1) * @row_h)
  end

  @doc "Constructors' championship table."
  def constructor_standings(rows, opts \\ []) do
    title = Keyword.get(opts, :title, "Campeonato de Constructores")

    body =
      rows
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {row, i} ->
        team = row["Constructor"] || %{}

        standing_row(
          @header_h + i * @row_h,
          row["position"],
          team["name"],
          team["nationality"],
          team["constructorId"],
          row["points"],
          wins_label(row["wins"])
        )
      end)

    wrap(title, "Pts", body, @header_h + max(length(rows), 1) * @row_h)
  end

  @doc "Finishing order of a single race."
  def race_results(race, opts \\ []) do
    results = Keyword.get(opts, :limit, 20) |> then(&Enum.take(race["Results"] || [], &1))
    title = "#{race["raceName"]} · #{race["season"]}"

    body =
      results
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {row, i} ->
        driver = row["Driver"] || %{}
        team = row["Constructor"] || %{}

        name =
          [driver["givenName"], driver["familyName"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        # A driver who didn't finish has no position of merit — show the status
        # ("Accident", "+1 Lap") instead of a time that doesn't exist.
        trailing = row["Time"]["time"] || row["status"] || ""

        standing_row(
          @header_h + i * @row_h,
          row["position"],
          name,
          team["name"],
          team["constructorId"],
          trailing,
          points_label(row["points"])
        )
      end)

    wrap(title, "Pts · Tiempo", body, @header_h + max(length(results), 1) * @row_h)
  end

  @doc "Upcoming races, with circuit and local start."
  def calendar(races, opts \\ []) do
    title = Keyword.get(opts, :title, "Calendario")
    shown = Enum.take(races, Keyword.get(opts, :limit, 12))

    body =
      shown
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {race, i} ->
        y = @header_h + i * @row_h
        baseline = y + div(@row_h, 2) + 4
        {date, time} = Colloq.F1.local_start(race)
        circuit = get_in(race, ["Circuit", "circuitName"]) || ""
        when_text = if time, do: "#{date} #{time}", else: date

        ~s(<text x="20" y="#{baseline}" font-size="11" fill="#{@muted}">R#{esc(race["round"])}</text>) <>
          ~s(<text x="58" y="#{baseline}" font-size="12.5" fill="#{@text}">#{esc(trim(race["raceName"], 30))}</text>) <>
          ~s(<text x="370" y="#{baseline}" font-size="11" fill="#{@muted}">#{esc(trim(circuit, 28))}</text>) <>
          ~s(<text x="700" y="#{baseline}" text-anchor="end" font-size="11.5" fill="#{@text}">#{esc(when_text)}</text>) <>
          ~s(<line x1="0" y1="#{y + @row_h}" x2="#{@width}" y2="#{y + @row_h}" stroke="#{@line}"/>)
      end)

    wrap(title, "Fecha (ARG)", body, @header_h + max(length(shown), 1) * @row_h)
  end

  @doc """
  One driver's season: a summary strip of totals, then race by race.

  `rows` are `Colloq.F1.driver_season/2` entries and `summary` a
  `Colloq.F1.season_summary/1` map.
  """
  def driver_card(driver, rows, summary, opts \\ []) do
    name = "#{driver["givenName"]} #{driver["familyName"]}"
    team_id = Keyword.get(opts, :constructor_id)
    color = Map.get(@team_colors, to_string(team_id), @default_color)
    subtitle = Keyword.get(opts, :subtitle, driver["nationality"])

    stats = [
      {"Carreras", summary.races},
      {"Puntos", format_points(summary.points)},
      {"Victorias", summary.wins},
      {"Podios", summary.podiums},
      {"Poles", summary.poles},
      {"Mejor", if(summary.best, do: "P#{summary.best}", else: "—")},
      {"Abandonos", summary.dnf}
    ]

    strip_h = 62
    header_end = @header_h + strip_h

    strip =
      stats
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{label, value}, i} ->
        x = 24 + i * 99

        ~s(<text x="#{x}" y="#{@header_h + 24}" font-size="10" text-transform="uppercase" fill="#{@muted}">#{esc(label)}</text>) <>
          ~s(<text x="#{x}" y="#{@header_h + 46}" font-size="17" font-weight="700" fill="#{@text}">#{esc(value)}</text>)
      end)

    races =
      rows
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {%{race: race, result: result}, i} ->
        y = header_end + i * @row_h
        baseline = y + div(@row_h, 2) + 4
        pos = result["position"]
        podium? = to_string(pos) in ["1", "2", "3"]
        grid = result["grid"]
        status = result["status"] || ""
        finished? = status == "Finished" or String.starts_with?(status, "+")

        bg =
          if podium?,
            do: ~s(<rect x="0" y="#{y}" width="#{@width}" height="#{@row_h}" fill="#{@highlight_bg}"/>),
            else: ""

        # A retirement is the story of that race — say so instead of printing a
        # finishing position that only means "classified last".
        outcome =
          if finished?,
            do: ~s(<text x="470" y="#{baseline}" font-size="12" font-weight="600" fill="#{@text}">P#{esc(pos)}</text>),
            else: ~s(<text x="470" y="#{baseline}" font-size="11" fill="#EA6A6A">#{esc(trim(status, 18))}</text>)

        bg <>
          ~s(<text x="30" y="#{baseline}" text-anchor="end" font-size="11" fill="#{@muted}">R#{esc(race["round"])}</text>) <>
          ~s(<text x="46" y="#{baseline}" font-size="12.5" fill="#{@text}">#{esc(trim(race["raceName"], 30))}</text>) <>
          ~s(<text x="380" y="#{baseline}" font-size="11" fill="#{@muted}">Grilla #{esc(grid)}</text>) <>
          outcome <>
          ~s(<text x="700" y="#{baseline}" text-anchor="end" font-size="12.5" font-weight="600" fill="#{@text}">#{esc(result["points"])} pts</text>) <>
          ~s(<line x1="0" y1="#{y + @row_h}" x2="#{@width}" y2="#{y + @row_h}" stroke="#{@line}"/>)
      end)

    height = header_end + max(length(rows), 1) * @row_h

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="#{esc(name)}">
    <rect width="#{@width}" height="#{height}" rx="10" fill="#{@bg}"/>
    <rect x="0" y="0" width="4" height="#{@header_h}" fill="#{color}"/>
    <text x="18" y="24" font-size="13" font-weight="700" fill="#{@text}">#{esc(name)}</text>
    <text x="700" y="24" text-anchor="end" font-size="11" fill="#{@muted}">#{esc(subtitle)}</text>
    <line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>
    #{strip}
    <line x1="0" y1="#{header_end}" x2="#{@width}" y2="#{header_end}" stroke="#{@line}"/>
    #{races}
    </svg>
    """
  end

  # 183.0 reads as 183; a half-point score keeps its decimal.
  defp format_points(points) when is_float(points) do
    if points == Float.round(points), do: trunc(points), else: points
  end

  defp format_points(points), do: points

  # --- shared drawing --------------------------------------------------------

  # One row: position, a team-coloured bar, name, subtitle, an optional
  # secondary column, and the trailing value.
  #
  # `secondary` arrives already formatted ("6V", "25 pts") rather than as a bare
  # number: the standings tables count wins there, the race results show points
  # scored, and the unit belongs to the caller that knows which it is.
  defp standing_row(y, position, name, subtitle, constructor_id, value, secondary) do
    color = Map.get(@team_colors, to_string(constructor_id), @default_color)
    baseline = y + div(@row_h, 2) + 4
    podium? = to_string(position) in ["1", "2", "3"]

    bg =
      if podium?,
        do: ~s(<rect x="0" y="#{y}" width="#{@width}" height="#{@row_h}" fill="#{@highlight_bg}"/>),
        else: ""

    secondary_text =
      if secondary in [nil, ""],
        do: "",
        else:
          ~s(<text x="622" y="#{baseline}" text-anchor="end" font-size="10.5" fill="#{@muted}">#{esc(secondary)}</text>)

    bg <>
      ~s(<text x="30" y="#{baseline}" text-anchor="end" font-size="12" font-weight="600" fill="#{@muted}">#{esc(position)}</text>) <>
      ~s(<rect x="42" y="#{y + 7}" width="3" height="#{@row_h - 14}" rx="1.5" fill="#{color}"/>) <>
      ~s(<text x="58" y="#{baseline}" font-size="12.5" fill="#{@text}">#{esc(trim(name, 26))}</text>) <>
      ~s(<text x="330" y="#{baseline}" font-size="11" fill="#{@muted}">#{esc(trim(subtitle, 24))}</text>) <>
      secondary_text <>
      ~s(<text x="700" y="#{baseline}" text-anchor="end" font-size="12.5" font-weight="600" fill="#{@text}">#{esc(value)}</text>) <>
      ~s(<line x1="0" y1="#{y + @row_h}" x2="#{@width}" y2="#{y + @row_h}" stroke="#{@line}"/>)
  end

  # Wins column for the championship tables — hidden at zero, since a column of
  # "0V" is noise.
  defp wins_label(wins) do
    if wins && to_string(wins) not in ["0", ""], do: "#{wins}V", else: nil
  end

  # Points scored in a single race. Shown even for a driver who finished out of
  # the points, because "0 pts" against P11 is the information.
  defp points_label(nil), do: nil
  defp points_label(points), do: "#{points} pts"

  defp wrap(title, right_label, body, height) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="#{esc(title)}">
    <rect width="#{@width}" height="#{height}" rx="10" fill="#{@bg}"/>
    <text x="20" y="24" font-size="12" font-weight="600" fill="#{@text}">#{esc(title)}</text>
    <text x="700" y="24" text-anchor="end" font-size="11" font-weight="600" fill="#{@muted}">#{esc(right_label)}</text>
    <line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>
    #{body}
    </svg>
    """
  end

  # SVG text neither wraps nor clips; count graphemes so accented names aren't
  # cut short.
  defp trim(nil, _max), do: ""

  defp trim(text, max) do
    text = to_string(text)
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
