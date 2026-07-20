defmodule Colloq.Sofascore.RoundSvg do
  @moduledoc """
  Renders one league round (fecha) as a self-contained SVG string.

  Takes raw Sofascore events (`homeTeam`, `awayTeam`, `homeScore`, `awayScore`,
  `status`, `startTimestamp`) and draws one row per match: both crests, both
  names, and a centre badge that is either the score (played) or the kickoff
  time (upcoming).

  Matches the visual language of `StandingsSvg` — same ground, rule colour and
  type scale — so the two replies read as one family. Replaces an HTML table
  that could not be styled at all: post bodies go through `basic_html`, which
  strips `class` and `style`, so the old reply was an unstyled browser table.
  """

  @width 720
  @header_h 38
  @row_h 40

  @bg "#0e1621"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @highlight_bg "#1b2431"
  @live "#3fb950"

  # Column anchors, left to right. SVG text doesn't wrap or clip on its own, so
  # every column needs enough room for its widest plausible value and the names
  # get truncated to match — see @max_name.
  #
  #   16   crest   38 …… name(end) 280   [badge 320]   360 name(start) …… 612
  #   618  crest  640                                        date(end) 704
  #
  # The away crest used to sit at 678 and the date was right-aligned at 706, so
  # the date drew straight over the crest; long away names ran under both.
  @home_crest_x 16
  @home_name_x 280
  @badge_cx 320
  @away_name_x 360
  @away_crest_x 618
  @date_x 704

  # Widest name that fits its column: ~250px at 12.5px in a UI sans is roughly
  # 26 characters.
  @max_name 26

  @doc """
  Render `events` to an SVG binary.

  Options:
    * `:highlight` — team-name substring to shade (default `"Racing"`)
    * `:title` — heading drawn in the header
  """
  def render(events, opts \\ []) when is_list(events) do
    highlight = opts |> Keyword.get(:highlight, "Racing") |> to_string() |> String.downcase()
    title = Keyword.get(opts, :title, "Fecha")

    rows =
      events
      |> Enum.sort_by(& &1["startTimestamp"])
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {event, i} ->
        row_svg(event, @header_h + i * @row_h, highlight)
      end)

    height = @header_h + max(length(events), 1) * @row_h

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="#{esc(title)}">
    <rect width="#{@width}" height="#{height}" rx="10" fill="#{@bg}"/>
    #{header_svg(title)}
    #{rows}
    </svg>
    """
  end

  defp header_svg(title) do
    ~s(<text x="20" y="24" font-size="12" font-weight="600" fill="#{@text}">#{esc(title)}</text>) <>
      ~s(<text x="#{@date_x}" y="24" text-anchor="end" font-size="11" font-weight="600" fill="#{@muted}">Día</text>) <>
      ~s(<line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>)
  end

  defp row_svg(event, y, highlight) do
    home = get_in(event, ["homeTeam", "name"]) || "?"
    away = get_in(event, ["awayTeam", "name"]) || "?"
    home_id = get_in(event, ["homeTeam", "id"])
    away_id = get_in(event, ["awayTeam", "id"])
    state = get_in(event, ["status", "type"])

    highlighted? =
      String.contains?(String.downcase(home), highlight) or
        String.contains?(String.downcase(away), highlight)

    cy = y + div(@row_h, 2)
    baseline = cy + 4

    bg =
      if highlighted?,
        do: ~s(<rect x="0" y="#{y}" width="#{@width}" height="#{@row_h}" fill="#{@highlight_bg}"/>),
        else: ""

    bg <>
      crest(home_id, @home_crest_x, cy - 11) <>
      ~s(<text x="#{@home_name_x}" y="#{baseline}" text-anchor="end" font-size="12.5" fill="#{@text}">#{esc(truncate(home))}</text>) <>
      centre_badge(event, state, cy) <>
      ~s(<text x="#{@away_name_x}" y="#{baseline}" font-size="12.5" fill="#{@text}">#{esc(truncate(away))}</text>) <>
      crest(away_id, @away_crest_x, cy - 11) <>
      ~s(<text x="#{@date_x}" y="#{baseline}" text-anchor="end" font-size="11" fill="#{@muted}">#{esc(day_only(event["startTimestamp"]))}</text>) <>
      ~s(<line x1="0" y1="#{y + @row_h}" x2="#{@width}" y2="#{y + @row_h}" stroke="#{@line}"/>)
  end

  # Played matches show the score; anything else shows the kickoff time, so a
  # round that is half-played reads correctly in one glance.
  defp centre_badge(event, state, cy) when state in ["finished", "inprogress"] do
    h = get_in(event, ["homeScore", "current"])
    a = get_in(event, ["awayScore", "current"])
    color = if state == "inprogress", do: @live, else: @text

    ~s(<text x="#{@badge_cx}" y="#{cy + 5}" text-anchor="middle" font-size="14" font-weight="700" fill="#{color}">#{h} - #{a}</text>)
  end

  defp centre_badge(event, _state, cy) do
    ~s(<text x="#{@badge_cx}" y="#{cy + 5}" text-anchor="middle" font-size="12" font-weight="600" fill="#{@muted}">#{esc(time_only(event["startTimestamp"]))}</text>)
  end

  defp crest(nil, _x, _y), do: ""

  defp crest(id, x, y) do
    ~s(<image href="https://api.sofascore.com/api/v1/team/#{id}/image" x="#{x}" y="#{y}" width="22" height="22"/>)
  end

  # Argentina is UTC-3 year round.
  #
  # The date column carries the day only. It used to render "23/07 19:30" while
  # the centre badge already showed "19:30" — the same time twice per row, and
  # the extra width is what pushed the date under the away crest.
  defp day_only(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!() |> DateTime.add(-3 * 3600, :second) |> Calendar.strftime("%d/%m")
  end

  defp day_only(_), do: ""

  defp time_only(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!() |> DateTime.add(-3 * 3600, :second) |> Calendar.strftime("%H:%M")
  end

  defp time_only(_), do: "-"

  # SVG text neither wraps nor clips, so names are cut to what their column
  # holds. String.slice/3 counts graphemes, not bytes — "Vélez" must not be
  # measured in bytes or accented names truncate early.
  defp truncate(name) do
    if String.length(name) > @max_name do
      String.slice(name, 0, @max_name - 1) <> "…"
    else
      name
    end
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
