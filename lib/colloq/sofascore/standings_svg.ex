defmodule Colloq.Sofascore.StandingsSvg do
  @moduledoc """
  Renders a Sofascore-style league table as a self-contained SVG string.

  Takes the raw `rows` from the Sofascore standings payload (`position`,
  `team`, `matches`, `wins`, `draws`, `losses`, `scoresFor`, `scoresAgainst`,
  `scoreDiffFormatted`, `points`, `promotion`) and draws a dark table with team
  crests, per-zone accent bars and section labels derived from `promotion.text`.

  We don't have the "Last 5" form here (Sofascore serves that from a separate
  endpoint), so that column is omitted; everything else in the widget is drawn.

  The SVG is embedded via a template component (not the sanitized post body),
  so inline markup and the external crest `<image href>` survive. Team names
  are XML-escaped since they come from an external source.
  """

  @width 720
  @header_h 38
  @row_h 34
  @section_h 28

  @bg "#0e1621"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @highlight_bg "#1b2431"

  # Right-aligned x for each numeric column, and the header label.
  @cols [{"P", 424}, {"W", 462}, {"D", 500}, {"L", 538}, {"DIFF", 596}, {"GLS", 656}, {"PTS", 706}]

  # Accent palette for zones, assigned in order of appearance; relegation is
  # always red regardless of its position in the list.
  @palette ["#3fb950", "#2dd4bf", "#3b82f6", "#d29922", "#a78bfa"]

  @doc """
  Render `rows` to an SVG binary. Options:
    * `:highlight` — team-name substring to shade (default `"Racing"`).
  """
  def render(rows, opts \\ []) when is_list(rows) do
    highlight = opts |> Keyword.get(:highlight, "Racing") |> to_string() |> String.downcase()
    zone_colors = zone_color_map(rows)

    {elements, height, _zone} =
      Enum.reduce(rows, {[], @header_h, nil}, fn row, {acc, y, cur_zone} ->
        zone = get_in(row, ["promotion", "text"])

        {acc, y} =
          if zone && zone != cur_zone do
            {[section_label(zone, y, zone_colors) | acc], y + @section_h}
          else
            {acc, y}
          end

        {[row_svg(row, y, zone_colors, highlight) | acc], y + @row_h, zone || cur_zone}
      end)

    body = elements |> Enum.reverse() |> Enum.join("\n")

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="Tabla de posiciones">
    <rect width="#{@width}" height="#{height}" rx="10" fill="#{@bg}"/>
    #{header_svg()}
    #{body}
    </svg>
    """
  end

  defp header_svg do
    labels =
      Enum.map_join(@cols, "", fn {label, x} ->
        ~s(<text x="#{x}" y="24" text-anchor="end" font-size="11" font-weight="600" fill="#{@muted}">#{label}</text>)
      end)

    ~s(<text x="46" y="24" font-size="11" font-weight="600" fill="#{@muted}">Equipo</text>) <>
      labels <>
      ~s(<line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>)
  end

  defp section_label(zone, y, zone_colors) do
    color = Map.get(zone_colors, zone, @muted)

    ~s(<rect x="0" y="#{y}" width="3" height="#{@section_h}" fill="#{color}"/>) <>
      ~s(<text x="14" y="#{y + 18}" font-size="11.5" font-weight="600" fill="#{color}">#{esc(zone)}</text>)
  end

  defp row_svg(row, y, zone_colors, highlight) do
    pos = row["position"] || "?"
    name = get_in(row, ["team", "name"]) || "?"
    team_id = get_in(row, ["team", "id"])
    zone = get_in(row, ["promotion", "text"])
    color = Map.get(zone_colors, zone, "transparent")

    gls = "#{row["scoresFor"] || 0}:#{row["scoresAgainst"] || 0}"
    diff = row["scoreDiffFormatted"] || fmt_diff((row["scoresFor"] || 0) - (row["scoresAgainst"] || 0))

    values = %{
      "P" => row["matches"] || row["played"] || 0,
      "W" => row["wins"] || 0,
      "D" => row["draws"] || 0,
      "L" => row["losses"] || 0,
      "DIFF" => diff,
      "GLS" => gls,
      "PTS" => row["points"] || 0
    }

    highlighted? = String.contains?(String.downcase(name), highlight)
    cy = y + div(@row_h, 2) + 4

    highlight_rect =
      if highlighted?,
        do: ~s(<rect x="0" y="#{y}" width="#{@width}" height="#{@row_h}" fill="#{@highlight_bg}"/>),
        else: ""

    crest =
      if team_id,
        do: ~s(<image href="#{crest(team_id)}" x="46" y="#{y + 7}" width="20" height="20"/>),
        else: ""

    name_weight = if highlighted?, do: "700", else: "500"

    nums =
      Enum.map_join(@cols, "", fn {label, x} ->
        bold = if label == "PTS", do: ~s( font-weight="700"), else: ""
        fill = if label == "PTS", do: @text, else: "#c7cdd8"
        ~s(<text x="#{x}" y="#{cy}" text-anchor="end" font-size="13" fill="#{fill}"#{bold}>#{esc(values[label])}</text>)
      end)

    highlight_rect <>
      ~s(<rect x="0" y="#{y}" width="3" height="#{@row_h}" fill="#{color}"/>) <>
      ~s(<text x="34" y="#{cy}" text-anchor="end" font-size="13" fill="#{@muted}">#{esc(pos)}</text>) <>
      crest <>
      ~s(<text x="74" y="#{cy}" font-size="13.5" font-weight="#{name_weight}" fill="#{@text}">#{esc(clip(name))}</text>) <>
      nums <>
      ~s(<line x1="0" y1="#{y + @row_h}" x2="#{@width}" y2="#{y + @row_h}" stroke="#{@line}"/>)
  end

  # Distinct zones in order of appearance → accent color. Relegation is always
  # red; the rest cycle through the palette.
  defp zone_color_map(rows) do
    rows
    |> Enum.map(&get_in(&1, ["promotion", "text"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce({%{}, 0}, fn zone, {map, idx} ->
      if relegation?(zone) do
        {Map.put(map, zone, "#e5484d"), idx}
      else
        {Map.put(map, zone, Enum.at(@palette, rem(idx, length(@palette)))), idx + 1}
      end
    end)
    |> elem(0)
  end

  defp relegation?(text) do
    String.contains?(String.downcase(text), ["releg", "descen"])
  end

  defp crest(id), do: "https://api.sofascore.com/api/v1/team/#{id}/image"

  defp fmt_diff(d) when d > 0, do: "+#{d}"
  defp fmt_diff(d), do: to_string(d)

  # Keep long club names from overflowing the name column.
  defp clip(name) when is_binary(name) do
    if String.length(name) > 26, do: String.slice(name, 0, 25) <> "…", else: name
  end

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
