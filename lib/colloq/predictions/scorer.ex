defmodule Colloq.Predictions.Scorer do
  @moduledoc """
  Módulo puro de puntuación de predicciones.

  Calcula los puntos que un usuario obtiene por una predicción
  comparándola con el resultado real del partido.

  Sistema de puntuación:
    - 3 puntos: resultado exacto (acertó ambos marcadores)
    - 2 puntos: resultado correcto + marcador cercano (dif ≤ 1 gol)
    - 1 punto: resultado correcto (local/empate/visitante)
    - 0 puntos: resultado incorrecto
  """

  @doc """
  Compara una predicción contra el resultado real y devuelve los puntos.

  ## Ejemplos
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
  Verifica si la predicción coincide exactamente con el resultado.
  """
  def exact_score?({h, a}, {h, a}), do: true
  def exact_score?(_, _), do: false

  @doc """
  Verifica si la predicción acierta el resultado (local/empate/visitante).
  """
  def right_result?({h1, a1}, {h2, a2}) do
    sign({h1, a1}) == sign({h2, a2})
  end

  @doc """
  Verifica si la predicción acierta el resultado y además la diferencia
  de goles es ≤ 1. Esto otorga 2 puntos.
  """
  def close_score?({h1, a1}, {h2, a2}) do
    right_result?({h1, a1}, {h2, a2}) and abs(h1 - h2) <= 1 and abs(a1 - a2) <= 1
  end

  defp sign({h, a}) when h > a, do: :local
  defp sign({h, a}) when h < a, do: :visitante
  defp sign({_, _}), do: :empate
end
