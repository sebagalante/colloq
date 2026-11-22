defmodule Colloq.Predictions.RoundUpsertTest do
  use Colloq.DataCase, async: true


  alias Colloq.Predictions
  alias Colloq.Predictions.Prediction

  defp entry(fixture_id, home, away, hs, as),
    do: %{fixture_id: fixture_id, home: home, away: away, home_score: hs, away_score: as}

  # The Prode switched from Sofascore to FotMob between two saves: the second
  # save must edit the first prediction, not add a duplicate for the same match.
  test "an edit after a switch of data source updates the same prediction" do
    user = insert(:user)

    {:ok, 1} = Predictions.upsert_round(user.id, 1, 14, [entry("16671646", "River Plate", "Racing Club", 1, 1)])
    {:ok, 1} = Predictions.upsert_round(user.id, 1, 14, [entry("fotmob:9", "River Plate", "Racing Club", 0, 2)])

    assert [%Prediction{fixture_id: "16671646", home_score: 0, away_score: 2}] = Repo.all(Prediction)

    matches = [%{fixture_id: "fotmob:9", home: "River Plate", away: "Racing Club"}]
    assert %{"fotmob:9" => %Prediction{away_score: 2}} = Predictions.for_user_round(user.id, 1, 14, matches)
  end

  test "a scored prediction is never overwritten" do
    user = insert(:user)

    {:ok, 1} = Predictions.upsert_round(user.id, 1, 14, [entry("1", "River Plate", "Racing Club", 1, 1)])
    Repo.update_all(Prediction, set: [scored_at: DateTime.utc_now()])

    assert {:ok, 0} =
             Predictions.upsert_round(user.id, 1, 14, [entry("fotmob:1", "River Plate", "Racing Club", 3, 0)])
  end
end
