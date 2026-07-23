defmodule Colloq.Workers.PredictionRoundScorerWorker do
  @moduledoc """
  Scores fecha-based predictions against the live Sofascore round payload.

  Runs on a short cron so finished matches of the current fecha are scored
  within minutes of full-time, and re-runs are cheap: one round fetch, and
  `Predictions.score_round/1` only touches predictions that aren't scored yet.

  With no `round` arg it scores the round being played now *and* the previous
  one — a match that kicked off late (or a fecha that straddles the anchor)
  might still be settling while the next round's matches begin.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  alias Colloq.{Predictions, Sofascore}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"round" => round}}) when is_integer(round) do
    score(round)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    current = Sofascore.current_round()

    [current, current - 1]
    |> Enum.filter(&(&1 >= 1))
    |> Enum.each(&score/1)

    :ok
  end

  defp score(round) do
    case Predictions.score_round(round) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("[PredictionRoundScorer] fecha #{round}: #{count} predicciones puntuadas")
        :ok

      {:error, :no_season} ->
        Logger.info("[PredictionRoundScorer] sin temporada configurada — nada que puntuar")
        :ok

      {:error, reason} ->
        Logger.warning("[PredictionRoundScorer] fecha #{round} falló: #{inspect(reason)}")
        :ok
    end
  end
end
