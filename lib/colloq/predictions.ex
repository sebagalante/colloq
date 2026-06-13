defmodule Colloq.Predictions do
  @moduledoc """
  Contexto de predicciones de partidos.

  Permite a los usuarios predecir resultados de fixtures,
  calcular puntuaciones y consultar tablas de posiciones.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Predictions.{Prediction, Scorer}

  @doc """
  Crea una predicción para un usuario en un fixture.

  Recibe user_id y attrs: fixture_id, home_score, away_score,
  first_scorer (opcional), motm (opcional).
  Retorna {:ok, prediction} o {:error, changeset}.
  """
  def create_prediction(user_id, attrs) do
    %Prediction{}
    |> Prediction.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
  end

  @doc """
  Obtiene todas las predicciones para un fixture.
  """
  def for_fixture(fixture_id) do
    Prediction
    |> where(fixture_id: ^fixture_id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Puntúa todas las predicciones de un fixture comparándolas
  con el resultado real.
  """
  def score_predictions_for_fixture(fixture_id, home_score, away_score) do
    predictions = for_fixture(fixture_id)
    result = %{home_score: home_score, away_score: away_score}

    Enum.each(predictions, fn pred ->
      points =
        Scorer.score(%{
          prediction: pred,
          result: result
        })

      pred
      |> Ecto.Changeset.change(points: points, scored_at: DateTime.utc_now())
      |> Repo.update!()
    end)

    {:ok, length(predictions)}
  end

  @doc """
  Tabla de posiciones (leaderboard) de predicciones.

  Opciones:
    - season: filtra por temporada (fixture_id que empieza con ese año)
    - limit: cantidad máxima de resultados (default 50)
  """
  def leaderboard(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    season = Keyword.get(opts, :season)

    Prediction
    |> filter_season(season)
    |> where([p], p.points > 0)
    |> group_by([p], p.user_id)
    |> select([p], %{
      user_id: p.user_id,
      total_points: sum(p.points),
      predictions_count: count(p.id),
      average_points: avg(p.points)
    })
    |> order_by(desc: :total_points)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(:user)
  end

  @doc """
  Comparación cabeza a cabeza entre dos usuarios en una temporada.
  """
  def head_to_head(user_a_id, user_b_id, opts \\ []) do
    season = Keyword.get(opts, :season)

    base =
      Prediction
      |> where([p], p.user_id in [^user_a_id, ^user_b_id])
      |> filter_season(season)
      |> where([p], p.points > 0 or p.scored_at != nil)
      |> preload(:user)

    user_a = Repo.all(where(base, [p], p.user_id == ^user_a_id))
    user_b = Repo.all(where(base, [p], p.user_id == ^user_b_id))

    %{
      user_a: %{
        points: Enum.sum(Enum.map(user_a, & &1.points)),
        count: length(user_a)
      },
      user_b: %{
        points: Enum.sum(Enum.map(user_b, & &1.points)),
        count: length(user_b)
      }
    }
  end

  @doc """
  Obtiene la predicción de un usuario para un fixture.
  """
  def get_user_prediction(user_id, fixture_id) do
    Repo.get_by(Prediction, user_id: user_id, fixture_id: fixture_id)
  end

  defp filter_season(query, nil), do: query
  defp filter_season(query, season) do
    where(query, [p], like(p.fixture_id, ^"#{season}%"))
  end
end
