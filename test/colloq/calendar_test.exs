defmodule Colloq.CalendarTest do
  use Colloq.DataCase, async: false
  import Colloq.Factory

  alias Colloq.Calendar

  # Trimmed from a real /api/data/matches payload.
  defp league(attrs, matches) do
    Map.merge(%{"id" => 1, "primaryId" => 1, "name" => "League", "matches" => matches}, attrs)
  end

  defp fm_match(id, home, away, utc, status) do
    %{
      "id" => id,
      "home" => Map.merge(%{"score" => 2}, home),
      "away" => Map.merge(%{"score" => 1}, away),
      "status" => Map.merge(%{"utcTime" => utc}, status)
    }
  end

  @racing %{"id" => 10_080, "name" => "Racing Club"}
  @boca %{"id" => 9, "name" => "Boca Juniors"}

  describe "parse/1" do
    test "maps status, minute, scores and the parent competition name" do
      [ft, live, ht, pre, pp] =
        Calendar.parse([
          league(%{"primaryId" => 112, "name" => "Liga Profesional"}, [
            fm_match(1, @racing, @boca, "2026-11-14T20:00:00.000Z", %{"started" => true, "finished" => true}),
            fm_match(2, @racing, @boca, "2026-11-14T21:00:00.000Z", %{"started" => true, "liveTime" => %{"short" => "67’"}}),
            fm_match(3, @racing, @boca, "2026-11-14T22:00:00.000Z", %{"started" => true, "reason" => %{"short" => "HT"}}),
            fm_match(4, @racing, @boca, "2026-11-14T23:00:00.000Z", %{"started" => false}),
            fm_match(5, @racing, @boca, "2026-11-14T23:30:00.000Z", %{
              "cancelled" => true,
              "reason" => %{"longKey" => "postponed"}
            })
          ]),
          league(%{"parentLeagueName" => "UEFA Nations League A", "name" => "UEFA Nations League A Grp. 4"}, [])
        ])

      assert ft.status == :finished and ft.home_score == 2 and ft.league_id == 112
      assert live.status == :live and live.minute == "67'"
      assert ht.status == :halftime
      assert pre.status == :prematch and is_nil(pre.home_score)
      assert pp.status == :postponed

      [m] =
        Calendar.parse([
          league(%{"parentLeagueName" => "UEFA Nations League A", "name" => "Grp. 4"}, [
            fm_match(9, %{"id" => 1, "name" => "Norway"}, %{"id" => 2, "name" => "Wales"}, "2026-11-14T17:00:00.000Z", %{})
          ])
        ])

      assert m.league_name == "UEFA Nations League A"
    end
  end

  describe "filter/2 and counts/1" do
    test "teams match by id, competitions by league id" do
      matches =
        Calendar.parse([
          league(%{"primaryId" => 112}, [fm_match(1, @racing, @boca, "2026-11-14T20:00:00.000Z", %{})]),
          league(%{"primaryId" => 114}, [
            fm_match(2, %{"id" => 6706, "name" => "Argentina"}, %{"id" => 5, "name" => "Uruguay"}, "2026-11-14T21:00:00.000Z", %{}),
            # Same name as Racing, different club: must not count.
            fm_match(3, %{"id" => 777, "name" => "Racing Club"}, %{"id" => 8, "name" => "Peñarol"}, "2026-11-14T22:00:00.000Z", %{})
          ])
        ])

      counts = Calendar.counts(matches)
      assert %{"racing" => 1, "argentina" => 1, "liga" => 1, "champions" => 0} = counts
      assert Enum.map(Calendar.filter(matches, ["argentina"]), & &1.id) == [2]
      assert Enum.map(Calendar.filter(matches, ["racing", "liga"]), & &1.id) == [1]
      assert Calendar.filter(matches, []) == []
    end
  end

  describe "default_filter_keys/0" do
    test "teams and the Liga start on, the other competitions are opt-in" do
      assert Calendar.default_filter_keys() == ["racing", "argentina", "liga"]
      assert length(Calendar.filters()) == 12
    end
  end

  describe "match_threads/1" do
    setup do
      kickoff = ~U[2026-11-14 22:00:00Z]

      [match] =
        Calendar.parse([league(%{}, [fm_match(42, @racing, @boca, DateTime.to_iso8601(kickoff), %{})])])

      %{match: match, kickoff: kickoff}
    end

    defp thread(title, inserted_at) do
      insert(:topic, title: title, is_match_thread: true, match_id: "123", inserted_at: inserted_at)
    end

    test "links a thread naming both teams opened days before", %{match: m, kickoff: k} do
      t = thread("Racing vs Boca — fecha 15", DateTime.add(k, -3, :day))
      assert %{42 => %{id: id}} = Calendar.match_threads([m])
      assert id == t.id
    end

    test "a thread naming one team counts only when opened within a day", %{match: m, kickoff: k} do
      thread("Racing vs los bosteros", DateTime.add(k, -3, :day))
      assert Calendar.match_threads([m]) == %{}

      t = thread("Hoy juega Racing!", DateTime.add(k, -5, :hour))
      assert %{42 => %{id: id}} = Calendar.match_threads([m])
      assert id == t.id
    end

    test "ignores ordinary topics and generic words", %{match: m, kickoff: k} do
      insert(:topic, title: "Racing Boca charla", inserted_at: DateTime.add(k, -1, :hour))
      # "Juniors" alone is not Boca.
      thread("Argentinos Juniors en casa", DateTime.add(k, -2, :day))
      assert Calendar.match_threads([m]) == %{}
    end
  end
end
