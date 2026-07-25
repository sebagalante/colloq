defmodule Colloq.FotMob do
  @moduledoc """
  Liga Profesional standings from FotMob — the fallback for when Sofascore,
  the primary source, can't answer.

  Same undocumented endpoint `Colloq.CopaArgentina` uses (`/api/data/leagues`,
  note the `data` segment), different league id. That module stays separate on
  purpose: Copa Argentina has *no* Sofascore equivalent, so it's a primary
  source there and a fallback here, and collapsing the two would hide which
  provider actually answered.

  Rows are mapped into the shape `Colloq.Sofascore.StandingsSvg` already draws,
  so the fallback renders through exactly the same path as the primary. Two
  things FotMob doesn't give us survive the mapping as gaps rather than
  guesses: zone/promotion labels (it encodes those as legend colours, not text)
  and the annual/averages tables (null on this feed).

  The whole payload is cached for 30 minutes.
  """

  require Logger

  @league_id 112
  @base "https://www.fotmob.com/api/data/leagues"
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  @cache_key "fotmob:liga:112"
  @ttl :timer.minutes(30)

  @doc """
  Current tournament's zone tables, as `{:ok, [{label, rows}]}`.

  FotMob returns every tournament of the season at once ("Clausura - Group A",
  "Apertura - Group A", …), current one first. We keep only the first
  tournament's zones, which is the running one — the same thing `/tabla` means.
  """
  def liga_standings do
    with {:ok, payload} <- league() do
      tables =
        payload
        |> get_in(["table"])
        |> List.wrap()
        |> List.first(%{})
        |> Map.get("data", %{})
        |> Map.get("tables", [])
        |> List.wrap()

      case current_tournament(tables) do
        [] -> {:error, :no_tables}
        current -> {:ok, Enum.map(current, &{label(&1), rows(&1)})}
      end
    end
  end

  # Tables are named "<Tournament> - Group <X>"; keep the ones belonging to the
  # tournament that appears first.
  defp current_tournament(tables) do
    case tables do
      [] ->
        []

      [first | _] ->
        tournament = tournament_of(first)
        Enum.filter(tables, &(tournament_of(&1) == tournament))
    end
  end

  defp tournament_of(table) do
    (table["leagueName"] || "") |> String.split(" - ") |> List.first() |> to_string()
  end

  # "Clausura - Group A" → "Clausura · Grupo A"
  defp label(table) do
    (table["leagueName"] || "")
    |> String.replace(~r/\bgroup\b/i, "Grupo")
    |> String.replace(" - ", " · ")
  end

  defp rows(table) do
    table
    |> get_in(["table", "all"])
    |> List.wrap()
    |> Enum.map(&map_row/1)
  end

  # FotMob row → the Sofascore row shape StandingsSvg draws.
  defp map_row(row) do
    {goals_for, goals_against} = parse_scores(row["scoresStr"])

    %{
      "position" => row["idx"],
      "team" => %{
        "name" => row["name"] || row["shortName"],
        "id" => row["id"],
        # FotMob ids don't resolve against Sofascore's crest host, so carry the
        # image URL explicitly rather than letting the renderer build one.
        "crest" => row["id"] && "https://images.fotmob.com/image_resources/logo/teamlogo/#{row["id"]}.png"
      },
      "matches" => row["played"],
      "wins" => row["wins"],
      "draws" => row["draws"],
      "losses" => row["losses"],
      "scoresFor" => goals_for,
      "scoresAgainst" => goals_against,
      "scoreDiffFormatted" => fmt_diff(row["goalConDiff"]),
      "points" => row["pts"]
    }
  end

  # "19-7" → {19, 7}
  defp parse_scores(str) when is_binary(str) do
    case String.split(str, "-") do
      [f, a] -> {to_int(f), to_int(a)}
      _ -> {0, 0}
    end
  end

  defp parse_scores(_), do: {0, 0}

  defp to_int(str) do
    case str |> String.trim() |> Integer.parse() do
      {n, _} -> n
      :error -> 0
    end
  end

  defp fmt_diff(d) when is_integer(d) and d > 0, do: "+#{d}"
  defp fmt_diff(d) when is_integer(d), do: to_string(d)
  defp fmt_diff(_), do: "0"

  defp league do
    case Cachex.get(:forum_cache, @cache_key) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      _ ->
        with {:ok, payload} <- fetch() do
          Cachex.put(:forum_cache, @cache_key, payload, ttl: @ttl)
          {:ok, payload}
        end
    end
  end

  defp fetch do
    case Req.get("#{@base}?id=#{@league_id}",
           headers: %{"user-agent" => @user_agent, "accept" => "application/json"},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      # An HTML body means FotMob served the SPA instead of JSON — usually the
      # sign that the undocumented endpoint moved.
      {:ok, %{status: 200}} ->
        Logger.warning("[FotMob] non-JSON body — endpoint may have changed")
        {:error, :unexpected_payload}

      {:ok, %{status: status}} ->
        Logger.warning("[FotMob] status #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[FotMob] request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
