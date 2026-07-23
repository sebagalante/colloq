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
  Scores all predictions for a fixture against the actual result.

  `result` is a map with `:home_score` and `:away_score`, optionally
  `:first_scorer` and `:motm` (see `Colloq.Predictions.Scorer`).

  Only unscored predictions are touched, so this is safe to re-run — the
  nightly sweep and the full-time hook can both fire for the same fixture
  without double-scoring or resurrecting a prediction an admin has adjusted.
  Returns `{:ok, count_scored}`.
  """
  def score_predictions_for_fixture(fixture_id, %{} = result) do
    now = DateTime.utc_now()

    predictions =
      Prediction
      |> where(fixture_id: ^fixture_id)
      |> where([p], is_nil(p.scored_at))
      |> Repo.all()

    Enum.each(predictions, fn pred ->
      points = Scorer.score(%{prediction: pred, result: result})

      pred
      |> Ecto.Changeset.change(points: points, scored_at: now)
      |> Repo.update!()
    end)

    {:ok, length(predictions)}
  end

  @doc """
  Score-only variant kept for callers that already hold the two numbers.
  """
  def score_predictions_for_fixture(fixture_id, home_score, away_score) do
    score_predictions_for_fixture(fixture_id, %{home_score: home_score, away_score: away_score})
  end

  @doc """
  Fixture ids that still have unscored predictions — the work list for the
  nightly sweep. Ordered oldest first so a backlog drains in match order.
  """
  def unscored_fixture_ids do
    Prediction
    |> where([p], is_nil(p.scored_at))
    |> group_by([p], p.fixture_id)
    |> order_by([p], min(p.inserted_at))
    |> select([p], p.fixture_id)
    |> Repo.all()
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
      # Scored predictions only — but keep the zero-point ones. Filtering on
      # `points > 0` used to drop anyone whose guesses all missed, so a player
      # with 10 wrong predictions vanished from the table instead of sitting at
      # the bottom with 0, and `average_points` was averaged over hits alone.
      |> where([p], not is_nil(p.scored_at))
      |> group_by([p], p.user_id)
      |> select([p], %{
        user_id: p.user_id,
        total_points: sum(p.points),
        predictions_count: count(p.id),
        average_points: avg(p.points)
      })
      # Order by the aggregate expression, not the select alias: `desc:
      # :total_points` compiles to `p0."total_points"`, a column that doesn't
      # exist, so this query raised 42703 for every caller.
      |> order_by([p], desc: sum(p.points))
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

  # ===========================================================================
  # Fecha (round) based predictions — Sofascore league rounds
  # ===========================================================================

  @doc """
  A user's predictions for one fecha, keyed by Sofascore `fixture_id` (string)
  so a template can look each match up in O(1).
  """
  def for_user_round(user_id, season_id, round) do
    Prediction
    |> where([p], p.user_id == ^user_id and p.season_id == ^season_id and p.round == ^round)
    |> Repo.all()
    |> Map.new(&{&1.fixture_id, &1})
  end

  @doc """
  Upserts a batch of predictions for one user across a fecha.

  `entries` is a list of `%{fixture_id, home_score, away_score}` maps (already
  parsed to integers). Each is inserted or updated on the
  `[user_id, fixture_id]` unique key. Returns `{:ok, count_saved}`.

  Callers are responsible for excluding matches whose deadline has passed —
  this trusts the list it's given, so the LiveView filters out locked fixtures
  before calling.
  """
  def upsert_round(user_id, season_id, round, entries) when is_list(entries) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.transaction(fn ->
        Enum.reduce(entries, 0, fn entry, acc ->
          attrs = %{
            "user_id" => user_id,
            "season_id" => season_id,
            "round" => round,
            "fixture_id" => to_string(entry.fixture_id),
            "home_score" => entry.home_score,
            "away_score" => entry.away_score
          }

          existing =
            Repo.get_by(Prediction, user_id: user_id, fixture_id: to_string(entry.fixture_id))

          # Never overwrite a prediction that was already scored — a late edit
          # must not rewrite history after the match finished.
          if existing && not is_nil(existing.scored_at) do
            acc
          else
            changeset = Prediction.changeset(existing || %Prediction{}, attrs)

            case Repo.insert_or_update(changeset) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end
        end)
      end)
      |> case do
        {:ok, n} -> {n, now}
        _ -> {0, now}
      end

    {:ok, count}
  end

  @doc """
  Scores every finished match of a fecha against the round's live payload.

  Pulls the round from Sofascore once, then scores predictions for each match
  the provider reports as finished. Safe to re-run — `score_predictions_for_fixture/2`
  only touches unscored rows. Returns `{:ok, total_scored}` or `{:error, reason}`.
  """
  def score_round(round) when is_integer(round) do
    case Colloq.Sofascore.round_fixtures(round) do
      {:ok, events} ->
        total =
          events
          |> Enum.reduce(0, fn event, acc ->
            case Colloq.Sofascore.event_result(event) do
              {:ok, result} ->
                {:ok, n} = score_predictions_for_fixture(to_string(event["id"]), result)
                acc + n

              {:error, :not_finished} ->
                acc
            end
          end)

        {:ok, total}

      other ->
        other
    end
  end

  defp filter_season(query, nil), do: query

  defp filter_season(query, season) when is_integer(season) do
    where(query, [p], p.season_id == ^season)
  end

  defp filter_season(query, season) do
    where(query, [p], like(p.fixture_id, ^"#{season}%"))
  end
end
