defmodule ColloqWeb.CalendarLiveTest do
  use ColloqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Colloq.Calendar

  @endpoint ColloqWeb.Endpoint
  @monday ~D[2026-11-09]

  # Seeds the day cache so the page never calls FotMob.
  defp seed_week(by_day) do
    for i <- 0..6 do
      date = Date.add(@monday, i)
      Cachex.put(:forum_cache, "calendar:fotmob:#{date}", Map.get(by_day, date, []))
    end

    on_exit(fn ->
      for i <- 0..6, do: Cachex.del(:forum_cache, "calendar:fotmob:#{Date.add(@monday, i)}")
    end)
  end

  defp match(id, home, away, kickoff, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        league_id: 114,
        league_name: "Friendlies",
        kickoff: kickoff,
        home: elem(home, 1),
        home_id: elem(home, 0),
        away: elem(away, 1),
        away_id: elem(away, 0),
        home_score: nil,
        away_score: nil,
        status: :prematch,
        minute: nil
      },
      extra
    )
  end

  test "shows followed matches, hides the rest, and toggles filters", %{conn: conn} do
    seed_week(%{
      ~D[2026-11-13] => [
        match(1, {6706, "Argentina"}, {5, "Uruguay"}, ~U[2026-11-13 23:00:00Z],
          %{status: :finished, home_score: 1, away_score: 2}),
        match(2, {50, "Norway"}, {51, "Wales"}, ~U[2026-11-13 17:00:00Z])
      ],
      ~D[2026-11-15] => [
        match(3, {10_080, "Racing Club"}, {9, "Boca Juniors"}, ~U[2026-11-15 22:00:00Z], %{league_id: 112})
      ]
    })

    {:ok, view, _html} = live(conn, "/calendario?semana=2026-11-12")
    html = render_async(view)

    # Any date in the week opens that week.
    assert html =~ "09/11"
    assert html =~ "Argentina"
    assert html =~ "Racing Club"
    # 22:00 UTC is 19:00 in Buenos Aires.
    assert html =~ "19:00"
    refute html =~ "Norway"

    html = view |> element("button[phx-value-key=argentina]") |> render_click()
    refute html =~ "Uruguay"
    assert html =~ "Racing Club"
  end

  test "other competitions are hidden until switched on", %{conn: conn} do
    seed_week(%{
      ~D[2026-11-11] => [
        match(4, {8456, "Manchester City"}, {8650, "Liverpool"}, ~U[2026-11-11 20:00:00Z], %{league_id: 47})
      ]
    })

    {:ok, view, _html} = live(conn, "/calendario?semana=2026-11-09")
    refute render_async(view) =~ "Liverpool"

    html = view |> element("button[phx-value-key=premier]") |> render_click()
    assert html =~ "Liverpool"
    assert html =~ "Premier"
  end

  test "links a match to its thread", %{conn: conn} do
    topic =
      Colloq.Factory.insert(:topic,
        title: "Racing vs Boca",
        slug: "racing-vs-boca",
        is_match_thread: true,
        match_id: "1",
        inserted_at: ~U[2026-11-14 12:00:00Z]
      )

    seed_week(%{
      ~D[2026-11-15] => [
        match(3, {10_080, "Racing Club"}, {9, "Boca Juniors"}, ~U[2026-11-15 22:00:00Z], %{league_id: 112})
      ]
    })

    {:ok, view, _html} = live(conn, "/calendario?semana=2026-11-09")
    assert render_async(view) =~ "/t/#{topic.id}/racing-vs-boca"
  end

  test "week_start/1 is the Monday" do
    assert Calendar.week_start(~D[2026-11-15]) == @monday
    assert Calendar.week_start(@monday) == @monday
  end
end
