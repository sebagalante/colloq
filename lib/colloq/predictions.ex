defmodule Colloq.Predictions do
  @moduledoc """
  Match prediction context.

  Allows users to predict fixture outcomes, calculate scores,
  and view leaderboards.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Predictions.{Prediction, Scorer}

  @doc """
  Creates a prediction for a user on a fixture.

  Receives user_id and attrs: fixture_id, home_score, away_score,
  first_scorer (optional), motm (optional).
  Returns {:ok, prediction} or {:error, changeset}.
  """
  def create_prediction(user_id, attrs) do
    %Prediction{}
    |> Prediction.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
  end

  @doc """
  Gets all predictions for a fixture.
  """
  def for_fixture(fixture_id) do
    Prediction
    |> where(fixture_id: ^fixture_id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Scores all predictions for a fixture by comparing them
  with the actual result.
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
  Predictions leaderboard.

  Options:
    - season: filters by season (fixture_id starting with that year)
    - limit: maximum number of results (default 50)
  """
  def leaderboard(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    season = Keyword.get(opts, :season)

    entries =
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

    user_ids = Enum.map(entries, & &1.user_id)
    users = Repo.all(from u in Colloq.Accounts.User, where: u.id in ^user_ids)
    users_map = Map.new(users, &{&1.id, &1})

    Enum.map(entries, fn entry ->
      Map.put(entry, :user, Map.get(users_map, entry.user_id))
    end)
  end

  @doc """
  Head-to-head comparison between two users in a season.
  """
  def head_to_head(user_a_id, user_b_id, opts \\ []) do
    season = Keyword.get(opts, :season)

    base =
      Prediction
      |> where([p], p.user_id in [^user_a_id, ^user_b_id])
      |> filter_season(season)
      |> where([p], p.points > 0 or not is_nil(p.scored_at))
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
  Gets a user's prediction for a fixture.
  """
  def get_user_prediction(user_id, fixture_id) do
    Repo.get_by(Prediction, user_id: user_id, fixture_id: fixture_id)
  end

  defp filter_season(query, nil), do: query
  defp filter_season(query, season) do
    where(query, [p], like(p.fixture_id, ^"#{season}%"))
  end
end
