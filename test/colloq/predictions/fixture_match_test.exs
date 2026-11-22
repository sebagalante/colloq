defmodule Colloq.Predictions.FixtureMatchTest do
  use ExUnit.Case, async: true

  alias Colloq.Predictions.FixtureMatch
  alias Colloq.Predictions.Prediction

  defp pred(id, fixture_id, home, away),
    do: %Prediction{id: id, fixture_id: fixture_id, home_team: home, away_team: away}

  defp match(fixture_id, home, away), do: %{fixture_id: fixture_id, home: home, away: away}

  test "pairs by id first" do
    p = pred(1, "123", nil, nil)
    assert FixtureMatch.pair([p], [match("123", "River Plate", "Racing Club")]) == %{"123" => p}
  end

  # The point of storing teams: a pick made on a Sofascore id still shows up
  # when the fecha is listed by FotMob, and the other way round.
  test "pairs by teams when the provider's ids differ" do
    p = pred(1, "16671646", "River Plate", "Racing Club")

    matches = [
      match("fotmob:1", "Boca Juniors", "Racing Club"),
      match("fotmob:2", "River Plate", "Racing Club")
    ]

    assert FixtureMatch.pair([p], matches) == %{"fotmob:2" => p}
  end

  test "tolerates accents, fillers and longer names" do
    p = pred(1, "1", "Club Atlético Platense", "Estudiantes de Río Cuarto")
    assert %{"fotmob:9" => ^p} = FixtureMatch.pair([p], [match("fotmob:9", "Platense", "Estudiantes de Rio Cuarto")])
  end

  # Two Estudiantes in the same fecha: the closer name wins and each match is
  # used once.
  test "assigns each match to its most similar prediction" do
    lp = pred(1, "a", "Estudiantes de La Plata", "Banfield")
    rc = pred(2, "b", "Estudiantes de Río Cuarto", "Lanús")

    matches = [
      match("fotmob:1", "Estudiantes", "Banfield"),
      match("fotmob:2", "Estudiantes de Rio Cuarto", "Lanus")
    ]

    assert FixtureMatch.pair([lp, rc], matches) == %{"fotmob:1" => lp, "fotmob:2" => rc}
  end

  test "both teams have to match" do
    p = pred(1, "1", "River Plate", "Racing Club")
    assert FixtureMatch.pair([p], [match("fotmob:1", "River Plate", "Boca Juniors")]) == %{}
  end

  test "predictions without stored teams only pair by id" do
    p = pred(1, "1", nil, nil)
    assert FixtureMatch.pair([p], [match("fotmob:1", "River Plate", "Racing Club")]) == %{}
  end
end
