defmodule Colloq.Predictions.Scorer do
  @moduledoc """
  Pure prediction scoring module.

  Calculates points a user earns for a prediction
  by comparing it against the actual match result.

  Scoring system:
    - 3 points: exact result (correct both scores)
    - 2 points: correct result + close score (diff ≤ 1 goal)
    - 1 point: correct outcome (home/draw/away)
    - 0 points: incorrect result
  """

  @doc """
  Compares a prediction against the actual result and returns the points.

  ## Examples
      iex> score(%{prediction: %{home_score: 2, away_score: 0}, result: %{home_score: 2, away_score: 0}})
      3

      iex> score(%{prediction: %{home_score: 1, away_score: 0}, result: %{home_score: 2, away_score: 0}})
      2

      iex> score(%{prediction: %{home_score: 2, away_score: 0}, result: %{home_score: 3, away_score: 0}})
      2

      iex> score(%{prediction: %{home_score: 3, away_score: 1}, result: %{home_score: 2, away_score: 0}})
      1

      iex> score(%{prediction: %{home_score: 0, away_score: 1}, result: %{home_score: 2, away_score: 0}})
      0
  """
  def score(%{prediction: pred, result: actual}) do
    pred_tuple = {pred.home_score, pred.away_score}
    actual_tuple = {actual.home_score, actual.away_score}

    cond do
      exact_score?(pred_tuple, actual_tuple) -> 3
      close_score?(pred_tuple, actual_tuple) -> 2
      right_result?(pred_tuple, actual_tuple) -> 1
      true -> 0
    end
  end

  @doc """
  Checks if the prediction exactly matches the result.
  """
  def exact_score?({h, a}, {h, a}), do: true
  def exact_score?(_, _), do: false

  @doc """
  Checks if the prediction gets the outcome (home/draw/away) right.
  """
  def right_result?({h1, a1}, {h2, a2}) do
    sign({h1, a1}) == sign({h2, a2})
  end

  @doc """
  Checks if the prediction gets the result right and additionally
  the goal difference is ≤ 1. This awards 2 points.
  """
  def close_score?({h1, a1}, {h2, a2}) do
    right_result?({h1, a1}, {h2, a2}) and abs(h1 - h2) <= 1 and abs(a1 - a2) <= 1
  end

  defp sign({h, a}) when h > a, do: :local
  defp sign({h, a}) when h < a, do: :visitante
  defp sign({_, _}), do: :empate
end
