defmodule Colloq.Predictions.Results do
  @moduledoc """
  Fetches the finished result of a fixture, in the shape `Scorer` expects.

  `predictions.fixture_id` is an **API-Football** fixture id — it comes from
  `topics.match_id`, which `ScoreBotWorker` polls against API-Football. Results
  are therefore read from the same provider; do not reach for Sofascore here,
  whose event ids are unrelated and would silently mismatch.

  Returns `{:ok, result}` only for matches API-Football reports as finished, so
  callers can safely score whatever comes back. A match still in progress gives
  `{:error, :not_finished}` rather than a half-time score.
  """

  require Logger

  # Statuses API-Football uses for a match that has actually concluded.
  # AET/PEN matter for cup ties; FT alone would leave those unscored forever.
  @finished_statuses ~w(FT AET PEN)

  defp api_base,
    do: Application.get_env(:colloq, :api_football_url, "https://v3.football.api-sports.io")

  defp api_key, do: Application.get_env(:colloq, :api_football_key)

  @doc """
  Fetches the final result for `fixture_id`.

  On success returns `{:ok, %{home_score:, away_score:, first_scorer:, motm:}}`.
  `motm` is always `nil` — see the note on `first_scorer/1` below.
  """
  def fetch_result(fixture_id) do
    with {:ok, %{home_score: h, away_score: a}} <- fetch_score(fixture_id) do
      {:ok,
       %{
         home_score: h,
         away_score: a,
         first_scorer: fetch_first_scorer(fixture_id),
         # API-Football exposes no man-of-the-match field. Reporting nil means
         # Scorer awards no MOTM bonus either way, which is the honest outcome:
         # inventing one from player ratings would hand out points on a guess.
         motm: nil
       }}
    end
  end

  @doc """
  The final score, or `{:error, :not_finished}` while the match is still live.
  """
  def fetch_score(fixture_id) do
    case get("/fixtures", fixture: fixture_id) do
      {:ok, %{"response" => [%{"goals" => goals, "fixture" => fixture} | _]}} ->
        status = get_in(fixture, ["status", "short"])

        cond do
          status not in @finished_statuses ->
            {:error, :not_finished}

          is_nil(goals["home"]) or is_nil(goals["away"]) ->
            {:error, :no_score}

          true ->
            {:ok, %{home_score: goals["home"], away_score: goals["away"]}}
        end

      {:ok, %{"response" => []}} ->
        {:error, :unknown_fixture}

      {:ok, _} ->
        {:error, :unexpected_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The scorer of the first goal, or `nil` if it can't be determined.

  Own goals are skipped: crediting the player who put it in their own net as
  "first scorer" is not what anyone predicted.
  """
  def fetch_first_scorer(fixture_id) do
    case get("/fixtures/events", fixture: fixture_id) do
      {:ok, %{"response" => events}} when is_list(events) ->
        events
        |> Enum.filter(&goal_event?/1)
        |> Enum.sort_by(&elapsed/1)
        |> List.first()
        |> case do
          nil -> nil
          event -> get_in(event, ["player", "name"])
        end

      _ ->
        nil
    end
  end

  defp goal_event?(%{"type" => "Goal"} = event),
    do: get_in(event, ["detail"]) != "Own Goal"

  defp goal_event?(_), do: false

  # Sort key: minute, then stoppage-time offset, so 45+2 follows 45.
  defp elapsed(event) do
    time = event["time"] || %{}
    {time["elapsed"] || 0, time["extra"] || 0}
  end

  defp get(path, params) do
    case api_key() do
      nil ->
        Logger.warning("[Predictions.Results] API_FOOTBALL_KEY not set — cannot fetch results")
        {:error, :no_api_key}

      key ->
        request(path, params, key)
    end
  end

  defp request(path, params, key) do
    case Req.get("#{api_base()}#{path}",
           params: params,
           headers: %{"x-rapidapi-key" => key, "x-rapidapi-host" => "v3.football.api-sports.io"},
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
