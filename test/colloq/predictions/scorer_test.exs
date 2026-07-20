defmodule Colloq.Predictions.ScorerTest do
  # Pure module — no Repo, so no DataCase and no sandbox.
  use ExUnit.Case, async: true
  doctest Colloq.Predictions.Scorer

  alias Colloq.Predictions.Scorer

  defp score(pred, actual), do: Scorer.score(%{prediction: pred, result: actual})

  describe "result points" do
    test "exact score is 3" do
      assert score(%{home_score: 2, away_score: 0}, %{home_score: 2, away_score: 0}) == 3
      assert score(%{home_score: 0, away_score: 0}, %{home_score: 0, away_score: 0}) == 3
    end

    test "right outcome within one goal on both sides is 2" do
      assert score(%{home_score: 1, away_score: 0}, %{home_score: 2, away_score: 0}) == 2
      assert score(%{home_score: 3, away_score: 1}, %{home_score: 2, away_score: 1}) == 2
    end

    test "right outcome but further off is 1" do
      assert score(%{home_score: 5, away_score: 0}, %{home_score: 2, away_score: 0}) == 1
    end

    test "wrong outcome is 0" do
      assert score(%{home_score: 0, away_score: 1}, %{home_score: 2, away_score: 0}) == 0
    end

    test "a predicted draw only pays out on a draw" do
      assert score(%{home_score: 1, away_score: 1}, %{home_score: 2, away_score: 2}) == 2
      assert score(%{home_score: 1, away_score: 1}, %{home_score: 2, away_score: 0}) == 0
    end

    test "close_score? requires the outcome to match, not just proximity" do
      # 1-0 vs 0-1: every score within one goal, but the winner is different.
      assert score(%{home_score: 1, away_score: 0}, %{home_score: 0, away_score: 1}) == 0
    end
  end

  describe "bonuses" do
    test "correct first scorer adds 2 on top of result points" do
      assert score(
               %{home_score: 2, away_score: 0, first_scorer: "Maravilla Martínez"},
               %{home_score: 2, away_score: 0, first_scorer: "Maravilla Martínez"}
             ) == 5
    end

    test "bonuses are independent of the result being right" do
      assert score(
               %{home_score: 0, away_score: 3, first_scorer: "Solari"},
               %{home_score: 2, away_score: 0, first_scorer: "Solari"}
             ) == 2
    end

    test "both bonuses stack" do
      assert score(
               %{home_score: 1, away_score: 0, first_scorer: "Solari", motm: "Arias"},
               %{home_score: 1, away_score: 0, first_scorer: "Solari", motm: "Arias"}
             ) == 7
    end

    test "name comparison folds case and collapses whitespace" do
      assert score(
               %{home_score: 1, away_score: 0, motm: "  gabriel   ARIAS "},
               %{home_score: 1, away_score: 0, motm: "Gabriel Arias"}
             ) == 5
    end

    test "wrong name earns nothing extra" do
      assert score(
               %{home_score: 1, away_score: 0, first_scorer: "Solari"},
               %{home_score: 1, away_score: 0, first_scorer: "Arias"}
             ) == 3
    end

    test "no bonus when the result has no such fact" do
      assert score(
               %{home_score: 1, away_score: 0, first_scorer: "Solari"},
               %{home_score: 1, away_score: 0}
             ) == 3
    end

    test "two blanks must not score a bonus" do
      assert score(
               %{home_score: 1, away_score: 0, first_scorer: "", motm: nil},
               %{home_score: 1, away_score: 0, first_scorer: "", motm: nil}
             ) == 3
    end

    test "a user who left the field empty is not punished" do
      assert score(
               %{home_score: 1, away_score: 0, first_scorer: ""},
               %{home_score: 1, away_score: 0, first_scorer: "Solari"}
             ) == 3
    end
  end

  describe "weights/0" do
    test "exposes the point values for the rules UI" do
      assert Scorer.weights() == %{
               exact: 3,
               close: 2,
               outcome: 1,
               first_scorer: 2,
               motm: 2
             }
    end
  end
end
