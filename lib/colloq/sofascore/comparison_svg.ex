defmodule Colloq.Sofascore.ComparisonSvg do
  @moduledoc """
  Renders a head-to-head player comparison as a self-contained SVG string.

  Takes two `%{name, id, stats}` maps (where `stats` is the raw `statistics`
  object from Sofascore's player-season endpoint) and draws diverging bars per
  stat: player A grows left of centre, player B grows right, each bar scaled to
  the larger of the two so the winner's bar always fills its side. The higher
  value in each row is drawn in the player's colour, the lower one muted.

  Like the standings SVG, this is embedded via a template component (not the
  sanitized post body), so inline markup and the external player `<image href>`
  survive. Player names come from an external source and are XML-escaped.
  """

  @width 720
  @pad 40
  @center 360
  @max_bar 150
  @gutter 8
  @header_h 96
  @row_h 46

  @bg "#0e1621"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @a_color "#3b82f6"
  @b_color "#f59e0b"
  @bar_bg "#1b2431"

  # {label, [keys tried in order], :int | :float}
  @stats [
    {"Goles", ["goals"], :int},
    {"Asistencias", ["assists"], :int},
    {"Partidos", ["appearances", "matchesPlayed"], :int},
    {"Minutos", ["minutesPlayed"], :int},
    {"Rating", ["rating"], :float},
    {"Remates", ["totalShots", "shotsOnTarget"], :int},
    {"Pases clave", ["keyPasses"], :int}
  ]

  @doc "Render the comparison to an SVG binary. `a`/`b` are `%{name, id, stats}`."
  def render(a, b) do
    height = @header_h + length(@stats) * @row_h + 12

    rows =
      @stats
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {stat, i} ->
        row_svg(stat, a.stats, b.stats, @header_h + i * @row_h)
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="Comparación de jugadores">
    <rect width="#{@width}" height="#{height}" rx="10" fill="#{@bg}"/>
    #{header_svg(a, b)}
    #{rows}
    </svg>
    """
  end

  defp header_svg(a, b) do
    photo_a =
      if a.id, do: ~s|<image href="#{photo(a.id)}" x="#{@pad}" y="20" width="48" height="48" clip-path="circle(24px at 24px 24px)"/>|, else: ""

    photo_b =
      if b.id, do: ~s|<image href="#{photo(b.id)}" x="#{@width - @pad - 48}" y="20" width="48" height="48" clip-path="circle(24px at 24px 24px)"/>|, else: ""

    ~s(<rect x="0" y="0" width="4" height="#{@header_h}" fill="#{@a_color}"/>) <>
      ~s(<rect x="#{@width - 4}" y="0" width="4" height="#{@header_h}" fill="#{@b_color}"/>) <>
      photo_a <>
      photo_b <>
      ~s(<text x="#{@pad + 60}" y="50" font-size="16" font-weight="700" fill="#{@a_color}">#{esc(clip(a.name))}</text>) <>
      ~s(<text x="#{@width - @pad - 60}" y="50" text-anchor="end" font-size="16" font-weight="700" fill="#{@b_color}">#{esc(clip(b.name))}</text>) <>
      ~s(<text x="#{@center}" y="50" text-anchor="middle" font-size="14" font-weight="700" fill="#{@muted}">VS</text>) <>
      ~s(<line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>)
  end

  defp row_svg({label, keys, kind}, stats_a, stats_b, y) do
    va = pick(stats_a, keys)
    vb = pick(stats_b, keys)
    maxv = max(va, vb)

    len_a = bar_len(va, maxv)
    len_b = bar_len(vb, maxv)

    a_wins = va > vb
    b_wins = vb > va
    a_fill = if a_wins, do: @a_color, else: @bar_bg
    b_fill = if b_wins, do: @b_color, else: @bar_bg
    a_txt = if a_wins, do: @text, else: @muted
    b_txt = if b_wins, do: @text, else: @muted

    bar_top = y + 24
    label_y = y + 17

    # A bar grows left from the gutter; B bar grows right.
    a_x = @center - @gutter - len_a
    b_x = @center + @gutter

    ~s(<text x="#{@center}" y="#{label_y}" text-anchor="middle" font-size="12" font-weight="600" fill="#{@muted}">#{esc(label)}</text>) <>
      ~s(<rect x="#{a_x}" y="#{bar_top}" width="#{len_a}" height="10" rx="3" fill="#{a_fill}"/>) <>
      ~s(<rect x="#{b_x}" y="#{bar_top}" width="#{len_b}" height="10" rx="3" fill="#{b_fill}"/>) <>
      ~s(<text x="#{@pad}" y="#{bar_top + 9}" font-size="13" font-weight="700" fill="#{a_txt}">#{fmt(va, kind)}</text>) <>
      ~s(<text x="#{@width - @pad}" y="#{bar_top + 9}" text-anchor="end" font-size="13" font-weight="700" fill="#{b_txt}">#{fmt(vb, kind)}</text>)
  end

  # First present key wins; missing/blank → 0. Handles the string/number values
  # Sofascore returns interchangeably.
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

  defp bar_len(_v, 0), do: 0
  defp bar_len(v, maxv), do: round(v / maxv * @max_bar)

  defp fmt(v, :float), do: :erlang.float_to_binary(v / 1.0, decimals: 2)
  defp fmt(v, _) when is_float(v), do: v |> round() |> Integer.to_string()
  defp fmt(v, _), do: to_string(v)

  defp photo(id), do: "https://api.sofascore.com/api/v1/player/#{id}/image"

  defp clip(name) when is_binary(name) do
    if String.length(name) > 18, do: String.slice(name, 0, 17) <> "…", else: name
  end

  defp clip(name), do: to_string(name)

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
