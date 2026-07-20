defmodule Colloq.CopaArgentina.Svg do
  @moduledoc """
  Renders Copa Argentina matches as a self-contained SVG card.

  Same ground, rule colour and type scale as `Colloq.Sofascore.RoundSvg` and
  `Colloq.F1.Svg`, so a CAbot reply sits beside a sofascorebot or FangioBot one
  without looking imported from somewhere else.

  No crests: FotMob's team images live on a different host, and an `<image
  href>` that 404s leaves a broken box inside the card. Names carry it instead,
  with the round as the left-hand column — in a cup the stage is the context
  that matters.
  """

  @width 720
  @header_h 38
  @row_h 34

  @bg "#0e1621"
  @line "#1c2531"
  @text "#e6e9ef"
  @muted "#8a94a6"
  @highlight_bg "#1b2431"
  @accent "#3b82f6"

  # Column anchors. Home is right-aligned into the centre, away left-aligned
  # out of it, so the score sits in a fixed column whatever the name lengths.
  @round_x 18
  @home_x 330
  @score_cx 366
  @away_x 402
  @when_x 702

  @max_name 26

  @doc """
  Render `matches` to an SVG binary.

  Options:
    * `:title` — heading (default "Copa Argentina")
    * `:highlight` — team-name substring to shade (default "Racing")
  """
  def matches(matches, opts \\ []) do
    title = Keyword.get(opts, :title, "Copa Argentina")
    highlight = opts |> Keyword.get(:highlight, "Racing") |> to_string() |> String.downcase()

    body =
      matches
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {match, i} ->
        row(match, @header_h + i * @row_h, highlight)
      end)

    height = @header_h + max(length(matches), 1) * @row_h

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{height}" width="100%" \
    style="max-width:#{@width}px;font-family:ui-sans-serif,system-ui,-apple-system,sans-serif" role="img" aria-label="#{esc(title)}">
    <rect width="#{@width}" height="#{height}" rx="10" fill="#{@bg}"/>
    <text x="#{@round_x}" y="24" font-size="12" font-weight="600" fill="#{@text}">#{esc(title)}</text>
    <text x="#{@when_x}" y="24" text-anchor="end" font-size="11" font-weight="600" fill="#{@muted}">Fecha (ARG)</text>
    <line x1="0" y1="#{@header_h}" x2="#{@width}" y2="#{@header_h}" stroke="#{@line}"/>
    #{body}
    </svg>
    """
  end

  defp row(match, y, highlight) do
    home = get_in(match, ["home", "name"]) || "?"
    away = get_in(match, ["away", "name"]) || "?"
    played? = Colloq.CopaArgentina.finished?(match)
    {date, time} = Colloq.CopaArgentina.local_kickoff(match)

    highlighted? =
      String.contains?(String.downcase(home), highlight) or
        String.contains?(String.downcase(away), highlight)

    baseline = y + div(@row_h, 2) + 4

    bg =
      if highlighted?,
        do: ~s(<rect x="0" y="#{y}" width="#{@width}" height="#{@row_h}" fill="#{@highlight_bg}"/>),
        else: ""

    # Played matches show the score; upcoming ones show "vs" so the row still
    # reads as a fixture rather than a blank gap.
    centre =
      if played? do
        ~s(<text x="#{@score_cx}" y="#{baseline}" text-anchor="middle" font-size="13" font-weight="700" fill="#{@text}">#{esc(Colloq.CopaArgentina.score(match))}</text>)
      else
        ~s(<text x="#{@score_cx}" y="#{baseline}" text-anchor="middle" font-size="11" fill="#{@muted}">vs</text>)
      end

    # Without a confirmed kickoff FotMob sends 00:00Z; showing the day alone is
    # honest, "21:00" would be invented.
    when_text = if time, do: "#{date} #{time}", else: date

    bg <>
      ~s(<text x="#{@round_x}" y="#{baseline}" font-size="10.5" fill="#{@accent}">#{esc(Colloq.CopaArgentina.round_name(match))}</text>) <>
      ~s(<text x="#{@home_x}" y="#{baseline}" text-anchor="end" font-size="12.5" fill="#{@text}">#{esc(trim(home))}</text>) <>
      centre <>
      ~s(<text x="#{@away_x}" y="#{baseline}" font-size="12.5" fill="#{@text}">#{esc(trim(away))}</text>) <>
      ~s(<text x="#{@when_x}" y="#{baseline}" text-anchor="end" font-size="11" fill="#{@muted}">#{esc(when_text)}</text>) <>
      ~s(<line x1="0" y1="#{y + @row_h}" x2="#{@width}" y2="#{y + @row_h}" stroke="#{@line}"/>)
  end

  # SVG text neither wraps nor clips; count graphemes so accented club names
  # aren't cut short.
  defp trim(name) do
    name = to_string(name)
    if String.length(name) > @max_name, do: String.slice(name, 0, @max_name - 1) <> "…", else: name
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
