defmodule Colloq.TeamSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Colloq.Sofascore
  alias Colloq.Sofascore.TeamSheet

  # Shapes copied from a real Sofascore payload (event 16431136).
  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "homeTeam" => %{"id" => 3215, "name" => "Racing Club"},
        "awayTeam" => %{"id" => 3217, "name" => "Gimnasia y Esgrima"},
        "referee" => %{
          "name" => "Nicolas Ramirez",
          "country" => %{"alpha3" => "ARG"},
          "games" => 136,
          "yellowCards" => 854,
          "redCards" => 34,
          "yellowRedCards" => 27
        },
        "status" => %{"type" => "inprogress"},
        "tournament" => %{"name" => "Liga Profesional"}
      },
      overrides
    )
  end

  defp player(name, number, opts \\ []) do
    %{
      "player" => %{"name" => name, "shortName" => name},
      "shirtNumber" => number,
      "position" => Keyword.get(opts, :position, "M"),
      "substitute" => Keyword.get(opts, :substitute, false)
    }
  end

  defp lineups(overrides \\ %{}) do
    Map.merge(
      %{
        "confirmed" => true,
        "home" => %{
          "formation" => "4-3-1-2",
          "playerColor" => %{"primary" => "ffffff", "number" => "11203b", "outline" => "ffffff"},
          "goalkeeperColor" => %{
            "primary" => "4bd82c",
            "number" => "ffffff",
            "outline" => "4bd82c"
          },
          "players" => [
            player("F. Cambeses", 25, position: "G"),
            player("E. Cannavo", 4),
            player("L. Díaz", 32, substitute: true)
          ],
          "missingPlayers" => [
            %{"player" => %{"shortName" => "A. Martínez"}, "description" => "red_card_suspension"}
          ]
        },
        "away" => %{
          "formation" => "4-4-2",
          "playerColor" => %{"primary" => "043565", "number" => "ffffff", "outline" => "043565"},
          "goalkeeperColor" => %{
            "primary" => "facc15",
            "number" => "000000",
            "outline" => "a16207"
          },
          "players" => [player("B. B. Schelotto", 31, position: "G"), player("G. Errecalde", 14)],
          "missingPlayers" => []
        }
      },
      overrides
    )
  end

  # event_data goes to the database as JSON, so the card has to render from what
  # comes back out — not from the map that happened to be built in memory.
  defp round_trip(data), do: data |> Jason.encode!() |> Jason.decode!()

  defp render(event, lineups) do
    render_component(&ColloqWeb.CoreComponents.team_sheet/1,
      sheet: round_trip(TeamSheet.build(event, lineups))
    )
  end

  describe "build/2" do
    test "splits the XI from the bench and keeps the absentees" do
      sheet = TeamSheet.build(event(), lineups())

      assert Enum.map(sheet["home"]["starters"], & &1["name"]) == ["F. Cambeses", "E. Cannavo"]
      assert Enum.map(sheet["home"]["bench"], & &1["name"]) == ["L. Díaz"]
      assert [%{"name" => "A. Martínez", "reason" => "Suspendido"}] = sheet["home"]["missing"]
      assert sheet["home"]["formation"] == "4-3-1-2"
      assert sheet["away"]["formation"] == "4-4-2"
    end

    test "marks the keeper so the card can paint the GK kit" do
      sheet = TeamSheet.build(event(), lineups())

      assert [%{"gk" => true}, %{"gk" => false}] = sheet["home"]["starters"]
    end

    test "separates a confirmed sheet from a probable one" do
      assert TeamSheet.build(event(), lineups())["confirmed"]
      refute TeamSheet.build(event(), lineups(%{"confirmed" => false}))["confirmed"]
      refute TeamSheet.build(event(), nil)["confirmed"]
    end

    test "survives a JSON round-trip unchanged" do
      sheet = TeamSheet.build(event(), lineups())

      assert round_trip(sheet) == sheet
    end

    test "degrades to the referee alone when there are no lineups" do
      sheet = TeamSheet.build(event(), nil)

      refute sheet["has_lineups"]
      assert sheet["home"]["starters"] == []
      assert sheet["home"]["name"] == "Racing Club"
      assert sheet["referee"]["name"] == "Nicolas Ramirez"
    end

    test "translates the absence reasons Sofascore ships as machine codes" do
      injured =
        put_in(lineups(), ["home", "missingPlayers"], [
          %{"player" => %{"shortName" => "J. Pérez"}, "description" => "Hamstring Injury"},
          %{
            "player" => %{"shortName" => "M. Gómez"},
            "description" => "yellow_or_red_card_suspension"
          }
        ])

      assert ["Lesión", "Suspendido"] =
               TeamSheet.build(event(), injured)["home"]["missing"] |> Enum.map(& &1["reason"])
    end

    test "drops a kit color that is not a plain hex triplet" do
      # Colors land in an inline style attribute, so anything that isn't six hex
      # digits has to be replaced rather than passed through.
      poisoned =
        put_in(lineups(), ["home", "playerColor"], %{
          "primary" => "red; background-image: url(x)",
          "number" => "fff",
          "outline" => nil
        })

      kit = TeamSheet.build(event(), poisoned)["home"]["kit"]

      assert kit["primary"] == "1b2431"
      assert kit["number"] == "e6e9ef"
      assert kit["outline"] == "3a4658"
    end
  end

  describe "team_sheet/1" do
    test "renders both XIs, the benches, the absentees and the referee" do
      html = render(event(), lineups())

      assert html =~ "F. Cambeses"
      assert html =~ "G. Errecalde"
      assert html =~ "L. Díaz"
      assert html =~ "A. Martínez"
      assert html =~ "Nicolas Ramirez"
      assert html =~ "4-3-1-2"
      assert html =~ "854"
    end

    test "paints each player chip in its team's kit" do
      html = render(event(), lineups())

      assert html =~ "background:#ffffff;color:#11203b"
      assert html =~ "background:#043565;color:#ffffff"
      # The keeper gets the goalkeeper kit, not the outfield one.
      assert html =~ "background:#4bd82c"
    end

    test "renders the referee-only card without empty lineup sections" do
      html = render(event(), nil)

      assert html =~ "Nicolas Ramirez"
      assert html =~ "Racing Club"
      refute html =~ "Substitutes"
    end

    test "renders with neither lineups nor referee" do
      html = render(event(%{"referee" => nil}), nil)

      refute html =~ "Referee"
      assert html =~ "Racing Club"
    end

    test "escapes club and player names" do
      hostile = put_in(event(), ["homeTeam", "name"], "<script>alert(1)</script>")
      html = render(hostile, lineups())

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "stacks the two teams on a narrow screen" do
      assert render(event(), lineups()) =~ "grid-cols-1"
    end
  end

  describe "Sofascore.referee/1" do
    test "flattens the official and their season tallies" do
      assert %{name: "Nicolas Ramirez", country: "ARG", games: 136, yellow: 854, red: 34} =
               Sofascore.referee(event())
    end

    test "is nil when no official is listed" do
      assert Sofascore.referee(event(%{"referee" => nil})) == nil
      assert Sofascore.referee(%{}) == nil
    end
  end
end
