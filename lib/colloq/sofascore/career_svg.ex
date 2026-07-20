defmodule Colloq.Sofascore.CareerSvg do
  @moduledoc """
  Renders a player's career table (one row per season-year, aggregated across
  competitions) as a self-contained SVG string — the static, post-friendly
  counterpart of the interactive `/jugador` table.

  Input is the `%{name, id, rows}` map from `Colloq.Sofascore.player_career/1`.
  Every external value is XML-escaped; crests load via `<image href>`.
  """

  @width 560
  @pad 20
  @header_h 84
  @col_head_h 26
  @row_h 30

  # Right-edge x for each numeric column.
  @c_pj 372
  @c_min 448
  @c_gls 500
  @c_ast 540

  @bg "#0e1621"
  @panel "#141d2b"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @accent "#3b82f6"

  @max_rows 14

  @doc "Render the career table to an SVG binary."
  def render(%{rows: rows} = career) do
    rows = Enum.take(rows, @max_rows)
    grid_top = @header_h + @col_head_h
    height = grid_top + length(rows) * @row_h + @pad

    body =
      rows
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {row, i} -> row_svg(row, grid_top + i * @row_h) end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="Carrera del jugador">
    <rect width="#{@width}" height="#{height}" rx="12" fill="#{@bg}"/>
    #{header_svg(career)}
    #{col_headers(@header_h)}
    #{body}
    </svg>
    """
  end

  defp header_svg(%{name: name, id: id, position: position}) do
    photo =
      if id,
        do:
          ~s|<image href="https://api.sofascore.com/api/v1/player/#{id}/image" x="#{@pad}" y="18" width="48" height="48" clip-path="circle(24px at 24px 24px)"/>|,
        else: ""

    ~s(<rect x="0" y="0" width="6" height="#{@header_h}" fill="#{@accent}"/>) <>
      photo <>
      ~s(<text x="#{@pad + 62}" y="42" font-size="18" font-weight="800" fill="#{@text}">#{esc(clip(name, 30))}</text>) <>
      ~s(<text x="#{@pad + 62}" y="62" font-size="12" fill="#{@muted}">#{esc(clip(position || "", 30))}</text>)
  end

  defp col_headers(y) do
    ~s(<rect x="0" y="#{y}" width="#{@width}" height="#{@col_head_h}" fill="#{@panel}"/>) <>
      label(@pad, y + 17, "start", "AÑO") <>
      label(90, y + 17, "start", "EQUIPO") <>
      label(@c_pj, y + 17, "end", "PJ") <>
      label(@c_min, y + 17, "end", "MIN") <>
      label(@c_gls, y + 17, "end", "GOL") <>
      label(@c_ast, y + 17, "end", "ASIS")
  end

  defp label(x, y, anchor, text) do
    ~s(<text x="#{x}" y="#{y}" text-anchor="#{anchor}" font-size="11" font-weight="700" fill="#{@muted}">#{esc(text)}</text>)
  end

  defp row_svg(row, y) do
    ty = y + 20

    crests =
      row.teams
      |> Enum.take(3)
      |> Enum.with_index()
      |> Enum.map_join("", fn {{tid, _}, i} ->
        ~s|<image href="https://api.sofascore.com/api/v1/team/#{tid}/image" x="#{90 + i * 22}" y="#{y + 5}" width="18" height="18"/>|
      end)

    ~s(<line x1="0" y1="#{y}" x2="#{@width}" y2="#{y}" stroke="#{@line}"/>) <>
      ~s(<text x="#{@pad}" y="#{ty}" font-size="13" font-weight="700" fill="#{@text}">#{esc(row.year)}</text>) <>
      crests <>
      num(@c_pj, ty, row.mp) <>
      num(@c_min, ty, row.min) <>
      num(@c_gls, ty, row.gls) <>
      num(@c_ast, ty, row.ast)
  end

  defp num(x, y, v) do
    ~s(<text x="#{x}" y="#{y}" text-anchor="end" font-size="13" fill="#{@text}" font-variant-numeric="tabular-nums">#{v}</text>)
  end

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
