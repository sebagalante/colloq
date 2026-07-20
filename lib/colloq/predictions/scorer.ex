defmodule Colloq.Predictions.Scorer do
  @moduledoc """
  Pure prediction scoring module.

  Calculates the points a user earns for a prediction by comparing it against
  the actual match result. No DB, no API — feed it two maps.

  ## Scoring

  Result points (mutually exclusive, best match wins):

    * 3 — exact score
    * 2 — correct outcome and every score within 1 goal
    * 1 — correct outcome (home/draw/away)
    * 0 — wrong outcome

  Bonus points, added on top and independent of the result points (you can miss
  the score entirely and still bank the scorer bonus):

    * +#{2} — correct first scorer
    * +#{2} — correct man of the match

  A bonus is only awarded when the *result* carries that fact. When the match
  data source doesn't supply `first_scorer`/`motm` (nil), no bonus is given
  either way — a missing fact never punishes and never rewards.
  """

  @exact_points 3
  @close_points 2
  @outcome_points 1
  @first_scorer_bonus 2
  @motm_bonus 2

  @doc """
  Compares a prediction against the actual result and returns total points.

  Both maps take `:home_score` and `:away_score`. Optionally `:first_scorer`
  and `:motm` — free-text player names, compared case- and whitespace-
  insensitively.

  ## Examples
      iex> alias Colloq.Predictions.Scorer
      iex> Scorer.score(%{prediction: %{home_score: 2, away_score: 0}, result: %{home_score: 2, away_score: 0}})
      3

      iex> alias Colloq.Predictions.Scorer
      iex> Scorer.score(%{prediction: %{home_score: 1, away_score: 0}, result: %{home_score: 2, away_score: 0}})
      2

      iex> alias Colloq.Predictions.Scorer
      iex> Scorer.score(%{prediction: %{home_score: 5, away_score: 0}, result: %{home_score: 2, away_score: 0}})
      1

      iex> alias Colloq.Predictions.Scorer
      iex> Scorer.score(%{prediction: %{home_score: 0, away_score: 1}, result: %{home_score: 2, away_score: 0}})
      0

  Bonuses stack on top of the result points:

      iex> alias Colloq.Predictions.Scorer
      iex> Scorer.score(%{
      ...>   prediction: %{home_score: 2, away_score: 0, first_scorer: "Adrián Martínez"},
      ...>   result: %{home_score: 2, away_score: 0, first_scorer: "adrián martínez"}
      ...> })
      5
  """
  def score(%{prediction: pred, result: actual}) do
    result_points(pred, actual) + bonus_points(pred, actual)
  end

  @doc "Just the 3/2/1/0 result component, without bonuses."
  def result_points(pred, actual) do
    pred_tuple = {pred.home_score, pred.away_score}
    actual_tuple = {actual.home_score, actual.away_score}

    cond do
      exact_score?(pred_tuple, actual_tuple) -> @exact_points
      close_score?(pred_tuple, actual_tuple) -> @close_points
      right_result?(pred_tuple, actual_tuple) -> @outcome_points
      true -> 0
    end
  end

  @doc "Just the first-scorer/MOTM bonus component."
  def bonus_points(pred, actual) do
    bonus(pred, actual, :first_scorer, @first_scorer_bonus) +
      bonus(pred, actual, :motm, @motm_bonus)
  end

  @doc "The point values, for display in rules/explainer UI."
  def weights do
    %{
      exact: @exact_points,
      close: @close_points,
      outcome: @outcome_points,
      first_scorer: @first_scorer_bonus,
      motm: @motm_bonus
    }
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

  defp bonus(pred, actual, key, points) do
    with guess when is_binary(guess) <- normalize(Map.get(pred, key)),
         truth when is_binary(truth) <- normalize(Map.get(actual, key)),
         true <- guess == truth do
      points
    else
      _ -> 0
    end
  end

  # Free-text player names: fold case and collapse whitespace so "Adrián
  # Martínez" and "adrián  martínez" agree. Blank/nil becomes nil, which the
  # `with` above treats as "no comparison possible" rather than a match — two
  # empty strings must not score a bonus.
  defp normalize(value) when is_binary(value) do
    case value |> String.trim() |> String.replace(~r/\s+/, " ") |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize(_), do: nil

  defp sign({h, a}) when h > a, do: :local
  defp sign({h, a}) when h < a, do: :visitante
  defp sign({_, _}), do: :empate
end
