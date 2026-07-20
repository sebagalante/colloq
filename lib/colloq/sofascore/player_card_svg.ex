defmodule Colloq.Sofascore.PlayerCardSvg do
  @moduledoc """
  Renders a single-player season stat card as a self-contained SVG string.

  Takes `%{name, id, position, team_name, season_label, stats}` where `stats` is
  the raw `statistics` object from Sofascore's player-season endpoint. Draws a
  header (photo + name + position/team + season badge) and a grid of stat tiles.

  Like the comparison/standings SVGs this is embedded via a template component
  (not the sanitized post body), so the external player `<image href>` survives.
  Every external value is XML-escaped here.
  """

  @pad 24
  @header_h 108
  @cols 3
  @tile_w 190
  @tile_h 66
  @tile_gap 12
  # Canvas width derived from the tile grid so the right column keeps its
  # padding (pad + 3 tiles + 2 gaps + pad).
  @width @pad * 2 + @cols * @tile_w + (@cols - 1) * @tile_gap

  @bg "#0e1621"
  @panel "#141d2b"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @accent "#3b82f6"

  # {label, [keys tried in order], :int | :float}. Rating leads; the rest are the
  # outfield staples. Missing keys render as 0 so the grid stays uniform.
  @stats [
    {"Rating", ["rating"], :float},
    {"Goles", ["goals"], :int},
    {"Asistencias", ["assists"], :int},
    {"Partidos", ["appearances", "matchesPlayed"], :int},
    {"Minutos", ["minutesPlayed"], :int},
    {"Remates", ["totalShots", "shotsOnTarget"], :int},
    {"Pases clave", ["keyPasses"], :int},
    {"Amarillas", ["yellowCards"], :int},
    {"Rojas", ["redCards"], :int}
  ]

  @doc "Render the card to an SVG binary from a `%{name, id, ...}` map."
  def render(card) do
    stats = Map.get(card, :stats) || %{}
    rows = ceil(length(@stats) / @cols)
    grid_top = @header_h + 12
    height = grid_top + rows * (@tile_h + @tile_gap) + @pad

    tiles =
      @stats
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {stat, i} ->
        col = rem(i, @cols)
        row = div(i, @cols)
        x = @pad + col * (@tile_w + @tile_gap)
        y = grid_top + row * (@tile_h + @tile_gap)
        tile_svg(stat, stats, x, y)
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="Ficha de jugador">
    <rect width="#{@width}" height="#{height}" rx="12" fill="#{@bg}"/>
    #{header_svg(card)}
    #{tiles}
    </svg>
    """
  end

  defp header_svg(card) do
    photo =
      if card[:id],
        do:
          ~s|<image href="#{photo_url(card[:id])}" x="#{@pad}" y="24" width="60" height="60" clip-path="circle(30px at 30px 30px)"/>| <>
            ~s|<circle cx="#{@pad + 30}" cy="54" r="30" fill="none" stroke="#{@accent}" stroke-width="2"/>|,
        else: ""

    tx = @pad + 76
    subtitle = [card[:position], card[:team_name]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

    season = card[:season_label]

    season_badge =
      if season && season != "" do
        w = 22 + String.length(to_string(season)) * 8
        ~s(<rect x="#{@width - @pad - w}" y="34" width="#{w}" height="26" rx="13" fill="#{@panel}" stroke="#{@line}"/>) <>
          ~s(<text x="#{@width - @pad - w / 2}" y="51" text-anchor="middle" font-size="13" font-weight="700" fill="#{@accent}">#{esc(season)}</text>)
      else
        ""
      end

    # Competition crest, sitting just left of the season badge.
    crest =
      if card[:tournament_id] do
        ~s|<image href="#{tournament_url(card[:tournament_id])}" x="#{@width - @pad - 96}" y="32" width="28" height="28"/>|
      else
        ""
      end

    ~s(<rect x="0" y="0" width="6" height="#{@header_h}" fill="#{@accent}"/>) <>
      photo <>
      ~s(<text x="#{tx}" y="50" font-size="20" font-weight="800" fill="#{@text}">#{esc(clip(card[:name], 26))}</text>) <>
      ~s(<text x="#{tx}" y="72" font-size="13" fill="#{@muted}">#{esc(clip(subtitle, 40))}</text>) <>
      crest <>
      season_badge <>
      ~s(<line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>)
  end

  defp tile_svg({label, keys, kind}, stats, x, y) do
    v = pick(stats, keys)

    ~s(<rect x="#{x}" y="#{y}" width="#{@tile_w}" height="#{@tile_h}" rx="8" fill="#{@panel}" stroke="#{@line}"/>) <>
      ~s(<text x="#{x + 14}" y="#{y + 30}" font-size="22" font-weight="800" fill="#{@text}">#{fmt(v, kind)}</text>) <>
      ~s(<text x="#{x + 14}" y="#{y + 50}" font-size="12" fill="#{@muted}">#{esc(label)}</text>)
  end

  # First present key wins; missing/blank → 0. Sofascore returns numbers or
  # numeric strings interchangeably.
  defp pick(stats, keys) when is_map(stats) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(stats, key) do
        nil -> nil
        "" -> nil
        v -> num(v)
      end
    end)
  end

  defp pick(_stats, _keys), do: 0

  defp num(v) when is_number(v), do: v

  defp num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp num(_), do: 0

  defp fmt(v, :float), do: :erlang.float_to_binary(v / 1.0, decimals: 2)
  defp fmt(v, _) when is_float(v), do: v |> round() |> Integer.to_string()
  defp fmt(v, _), do: to_string(v)

  defp photo_url(id), do: "https://api.sofascore.com/api/v1/player/#{id}/image"

  defp tournament_url(id), do: "https://api.sofascore.com/api/v1/unique-tournament/#{id}/image"

  defp clip(nil, _), do: ""

  defp clip(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end

  defp clip(s, _), do: to_string(s)

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
