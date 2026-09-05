defmodule Colloq.Sofascore.OfficialRoster do
  @moduledoc """
  Racing Club's first-team squad, scraped from the official site
  (racingclub.com.ar/futbol/primer-equipo/plantel).

  This is the authority for Racing — Sofascore's feed lags on transfers and
  loan numbers, and it keeps players at their former club for weeks after a
  move, which is enough to drop them from our board entirely.

  The page is server-rendered: one `<li>` per player carrying the full name in
  the photo's `alt`, the surname in `.nombre strong`, and `.posicion` /
  `.numero` spans. Nothing here depends on JS.
  """

  @url "https://www.racingclub.com.ar/futbol/primer-equipo/plantel"
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"

  # Sanity floor. A first team is ~30 players; a handful means the markup moved
  # and we parsed navigation chrome, in which case yesterday's squad is a far
  # better answer than wiping the board.
  @min_players 20

  @goalkeeper "Arquero"

  @doc "The page this roster is scraped from."
  def url, do: @url

  @doc """
  Fetches and parses the official squad.

  Returns `{:ok, players}` — each `%{number, name, surname, position}` plus a
  `:short` pitch label when two players share a surname — or `{:error, reason}`
  when the site is unreachable or the parse looks implausible. Callers must
  treat an error as "leave the stored squad alone", never as an empty squad.
  """
  def fetch(opts \\ []) do
    url = Keyword.get(opts, :url, @url)

    case Req.get(url,
           headers: %{"user-agent" => @user_agent, "accept" => "text/html"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        parse(html)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses the squad out of the plantel page's HTML.

  Split from `fetch/1` so the parser can be exercised on a saved page without
  hitting the club's site.
  """
  def parse(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        players =
          doc
          |> Floki.find("li")
          |> Enum.flat_map(&player/1)
          |> Enum.uniq_by(& &1.number)
          |> Enum.sort_by(& &1.number)

        validate(players)

      {:error, reason} ->
        {:error, {:unparsable_html, reason}}
    end
  end

  defp validate(players) when length(players) < @min_players,
    do: {:error, {:implausible_squad, length(players)}}

  defp validate(players) do
    if Enum.any?(players, &(&1.position == @goalkeeper)) do
      {:ok, disambiguate(players)}
    else
      {:error, :no_goalkeeper}
    end
  end

  # One `<li>` → zero or one player. A list item without both a shirt number
  # and a position is page furniture (menus, footer links), not a player.
  defp player(li) do
    with {:ok, number} <- number(li),
         position when position != "" <- text(li, "span.posicion"),
         surname when surname != "" <- li |> text("div.nombre strong") |> String.trim_trailing(","),
         name when name != "" <- full_name(li, surname) do
      [%{number: number, name: name, surname: surname, position: position}]
    else
      _ -> []
    end
  end

  defp number(li) do
    case li |> text("span.numero") |> Integer.parse() do
      {n, _rest} -> {:ok, n}
      :error -> :error
    end
  end

  # The photo's `alt` carries the full legal name ("Claudio Matías
  # Kranevitter"); the anchor text is "Surname, given names" and is the
  # fallback when a player has no photo yet.
  defp full_name(li, surname) do
    case li |> Floki.attribute("img", "alt") |> List.first() do
      alt when is_binary(alt) and alt != "" ->
        squish(alt)

      _ ->
        case li |> text("div.nombre a") |> String.split(",", parts: 2) do
          [_surname, given] -> "#{String.trim(given)} #{surname}"
          _ -> surname
        end
    end
  end

  defp text(li, selector) do
    li |> Floki.find(selector) |> Floki.text() |> squish()
  end

  # The page indents with tabs and double-spaces a few names; collapse it all so
  # stored names compare cleanly against Sofascore's.
  defp squish(str), do: str |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Two players with the same surname need an initial on the pitch, or the
  # board shows "Martínez" twice. Only the clashing ones get a `:short`.
  defp disambiguate(players) do
    counts = Enum.frequencies_by(players, &normalize(&1.surname))

    Enum.map(players, fn player ->
      if Map.get(counts, normalize(player.surname), 0) > 1 do
        Map.put(player, :short, "#{initial(player)}. #{player.surname}")
      else
        player
      end
    end)
  end

  # First given name's initial — the full name minus the trailing surname.
  defp initial(%{name: name, surname: surname}) do
    name
    |> String.replace_suffix(surname, "")
    |> String.trim()
    |> String.first()
    |> case do
      nil -> String.first(name)
      letter -> letter
    end
  end

  defp normalize(str) do
    str
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.trim()
  end
end
