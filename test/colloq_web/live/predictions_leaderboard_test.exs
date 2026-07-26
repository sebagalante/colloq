defmodule ColloqWeb.PredictionsLeaderboardTest do
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory
  import ColloqWeb.Gettext

  alias Colloq.Repo
  alias Colloq.Predictions.Prediction

  @endpoint ColloqWeb.Endpoint
  @season 87_913

  defp scored(user, points, fixture) do
    Repo.insert!(%Prediction{
      user_id: user.id,
      season_id: @season,
      round: 1,
      fixture_id: fixture,
      home_score: 1,
      away_score: 0,
      points: points,
      scored_at: DateTime.utc_now()
    })
  end

  defp open_table(conn, user) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    live(conn, "/predicciones/tabla")
  end

  setup do
    Colloq.SiteSettings.put("sofascore_season_id", to_string(@season), type: "integer")
    :ok
  end

  test "ranks players by total points and shows every column", %{conn: conn} do
    leader = insert(:user, username: "leader")
    trailer = insert(:user, username: "trailer")

    scored(leader, 5, "a")
    scored(leader, 3, "b")
    scored(trailer, 1, "c")

    {:ok, _view, html} = open_table(conn, leader)

    assert html =~ "leader"
    assert html =~ "trailer"
    # Total points, prediction count, and the average column the old card
    # never rendered.
    assert html =~ "8"
    assert html =~ "4.00"

    leader_at = :binary.match(html, "leader") |> elem(0)
    trailer_at = :binary.match(html, "trailer") |> elem(0)
    assert leader_at < trailer_at, "higher total should sort first"
  end

  test "keeps players whose predictions all scored zero", %{conn: conn} do
    zero = insert(:user, username: "zeroguy")
    scored(zero, 0, "a")

    {:ok, _view, html} = open_table(conn, zero)

    assert html =~ "zeroguy"
  end

  test "ignores unscored predictions", %{conn: conn} do
    user = insert(:user, username: "pending")

    Repo.insert!(%Prediction{
      user_id: user.id,
      season_id: @season,
      round: 1,
      fixture_id: "x",
      home_score: 2,
      away_score: 2,
      points: 0,
      scored_at: nil
    })

    {:ok, _view, html} = open_table(conn, user)

    assert html =~ "No scored predictions this season yet." or
             not (html =~ ~s(id="prediction-row"))
  end

  test "the predictions page links to the table instead of embedding it", %{conn: conn} do
    user = insert(:user)
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})

    {:ok, _view, html} = live(conn, "/predicciones")

    assert html =~ "/predicciones/tabla"
  end

  test "both prode pages explain the scoring, using the scorer's own numbers", %{conn: conn} do
    user = insert(:user)
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    w = Colloq.Predictions.Scorer.weights()

    # Assert through gettext, not English literals: the app's default locale is
    # Spanish, so hardcoded msgids fail the moment a string is translated.
    for path <- ["/predicciones", "/predicciones/tabla"] do
      {:ok, _view, html} = live(conn, path)

      assert html =~ pgettext("prode", "How does scoring work?"), "no explainer on #{path}"
      assert html =~ pgettext("prode", "Exact score"), "no result tiers on #{path}"
      assert html =~ to_string(w.exact), "no max-points line on #{path}"

      # Both bonuses are scored by Scorer but no form collects them, so the
      # explainer must not advertise points a player has no way to earn.
      refute html =~ pgettext("prode", "First scorer"), "first scorer advertised on #{path}"
      refute html =~ pgettext("prode", "Man of the match"), "MOTM advertised on #{path}"
    end
  end
end
