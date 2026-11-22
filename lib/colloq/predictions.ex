defmodule Colloq.Predictions do
  @moduledoc """
  Match prediction context.

  Allows users to predict fixture outcomes, calculate scores,
  and view leaderboards.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Predictions.{FixtureMatch, Prediction, Scorer}

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
  # Fecha (round) based predictions
  #
  # The fecha comes from Sofascore or FotMob (`Colloq.DataSource`), whose match
  # ids differ, so predictions are paired with the shown matches by id first
  # and by teams second (`Colloq.Predictions.FixtureMatch`).
  # ===========================================================================

  @doc """
  A user's predictions for one fecha, keyed by the `fixture_id` of the match in
  `matches` each one belongs to, so a template can look each match up in O(1)
  whichever provider listed the fecha. `matches` are maps with `:fixture_id`,
  `:home` and `:away`.
  """
  def for_user_round(user_id, season_id, round, matches) do
    user_id
    |> user_round_predictions(season_id, round)
    |> FixtureMatch.pair(matches)
  end

  defp user_round_predictions(user_id, season_id, round) do
    Prediction
    |> where([p], p.user_id == ^user_id and p.season_id == ^season_id and p.round == ^round)
    |> Repo.all()
  end

  @doc """
  Upserts a batch of predictions for one user across a fecha.

  `entries` is a list of `%{fixture_id, home, away, home_score, away_score}`
  maps (scores already parsed to integers). An entry updates the prediction
  already paired with that match — same id, or same teams after a switch of
  data source — and inserts one otherwise. Returns `{:ok, count_saved}`.

  Callers are responsible for excluding matches whose deadline has passed —
  this trusts the list it's given, so the LiveView filters out locked fixtures
  before calling.
  """
  def upsert_round(user_id, season_id, round, entries) when is_list(entries) do
    Repo.transaction(fn ->
      existing_by_match =
        user_id
        |> user_round_predictions(season_id, round)
        |> FixtureMatch.pair(entries)

      Enum.reduce(entries, 0, fn entry, acc ->
        existing = existing_by_match[to_string(entry.fixture_id)]

        attrs =
          %{
            "user_id" => user_id,
            "season_id" => season_id,
            "round" => round,
            "home_team" => entry[:home],
            "away_team" => entry[:away],
            "home_score" => entry.home_score,
            "away_score" => entry.away_score
          }
          # A paired prediction keeps its original id: the unique key is
          # [user_id, fixture_id] and the teams already tie it to this match.
          |> Map.put("fixture_id", (existing && existing.fixture_id) || to_string(entry.fixture_id))

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
      {:ok, n} -> {:ok, n}
      _ -> {:ok, 0}
    end
  end

  # How long before a match its predictions can have been made. Fecha numbers
  # repeat between the Apertura and the Clausura, so an unscored pick from the
  # other tournament must not be paired with this one's match by teams.
  @pairing_window_seconds 30 * 86_400

  @doc """
  Scores every finished match of a fecha against the round's payload.

  Pulls the round once from the Prode's data source (falling back to the other
  provider), pairs each user's unscored predictions with its matches, and
  scores the ones whose match is finished. Safe to re-run — only unscored rows
  are touched. Returns `{:ok, total_scored}` or `{:error, reason}`.
  """
  def score_round(round) when is_integer(round) do
    case Colloq.Sofascore.round_fixtures(round) do
      {:ok, events} ->
        finished =
          Enum.flat_map(events, fn event ->
            case Colloq.Sofascore.event_result(event) do
              {:ok, result} ->
                [
                  %{
                    fixture_id: to_string(event["id"]),
                    home: get_in(event, ["homeTeam", "name"]),
                    away: get_in(event, ["awayTeam", "name"]),
                    kickoff: event["startTimestamp"],
                    result: result
                  }
                ]

              {:error, :not_finished} ->
                []
            end
          end)

        {:ok, score_finished(round, finished)}

      other ->
        other
    end
  end

  defp score_finished(_round, []), do: 0

  defp score_finished(round, finished) do
    now = DateTime.utc_now()
    earliest = finished |> Enum.map(&(&1.kickoff || 0)) |> Enum.min()
    since = DateTime.from_unix!(max(earliest - @pairing_window_seconds, 0))
    by_id = Map.new(finished, &{&1.fixture_id, &1})

    Prediction
    |> where([p], p.round == ^round and is_nil(p.scored_at))
    |> where([p], p.inserted_at >= ^since or p.fixture_id in ^Map.keys(by_id))
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
    |> Enum.reduce(0, fn {_user_id, predictions}, acc ->
      predictions
      |> FixtureMatch.pair(finished)
      |> Enum.reduce(acc, fn {fixture_id, pred}, acc ->
        points = Scorer.score(%{prediction: pred, result: by_id[fixture_id].result})

        pred
        |> Ecto.Changeset.change(points: points, scored_at: now)
        |> Repo.update!()

        acc + 1
      end)
    end)
  end

  defp filter_season(query, nil), do: query

  defp filter_season(query, season) when is_integer(season) do
    where(query, [p], p.season_id == ^season)
  end

  defp filter_season(query, season) do
    where(query, [p], like(p.fixture_id, ^"#{season}%"))
  end
end
