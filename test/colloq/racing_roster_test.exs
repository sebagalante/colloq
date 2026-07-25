defmodule Colloq.RacingRosterTest do
  use Colloq.DataCase, async: true

  alias Colloq.Sofascore
  alias Colloq.Sofascore.{SofascorePlayer, RacingRoster}

  @racing Sofascore.racing_team_id()

  defp seed(attrs) do
    %SofascorePlayer{}
    |> SofascorePlayer.changeset(Map.merge(%{team_id: @racing}, attrs))
    |> Repo.insert!()
  end

  test "the roster is the 32 players, uniquely numbered" do
    players = RacingRoster.players()
    assert length(players) == 32
    numbers = Enum.map(players, & &1.number)
    assert numbers == Enum.uniq(numbers)
  end

  describe "apply_racing_roster/0" do
    test "matches an existing row by name and keeps its sofascore_id" do
      # Sofascore had the wrong number and a shorter name.
      seed(%{sofascore_id: "992093", name: "Lautaro Díaz", jersey_number: 19, position: "Delantero"})

      Sofascore.apply_racing_roster()

      row = Repo.get_by!(SofascorePlayer, sofascore_id: "992093")
      assert row.jersey_number == 32
      assert row.name == "Lautaro Ariel Diaz"
    end

    test "inserts an official player absent from the stored squad" do
      Sofascore.apply_racing_roster()

      # De Bellis isn't seeded here, so he must be created with a synthetic id.
      row = Repo.get_by!(SofascorePlayer, jersey_number: 12)
      assert row.name == "Thiago De Bellis"
      assert row.sofascore_id == "racing-official-12"
    end

    test "removes a stored player not on the official list" do
      seed(%{sofascore_id: "1177565", name: "Damián Pizarro", jersey_number: 14, position: "Delantero"})

      Sofascore.apply_racing_roster()

      refute Repo.get_by(SofascorePlayer, sofascore_id: "1177565")
    end

    test "disambiguates two players sharing a surname" do
      seed(%{sofascore_id: "1113236", name: "Ignacio Rodríguez", jersey_number: 19, position: "Defensor"})
      seed(%{sofascore_id: "1201515", name: "Baltasar Rodriguez", jersey_number: 20, position: "Mediocampista"})

      Sofascore.apply_racing_roster()

      # Each keeps its own id — the compound "Luis Rodríguez" still finds Baltasar.
      assert Repo.get_by!(SofascorePlayer, sofascore_id: "1113236").jersey_number == 19
      assert Repo.get_by!(SofascorePlayer, sofascore_id: "1201515").jersey_number == 20
    end

    test "leaves the squad matching the official list exactly, and is idempotent" do
      Sofascore.apply_racing_roster()
      first = Sofascore.list_by_team(@racing) |> Enum.map(&{&1.jersey_number, &1.name}) |> Enum.sort()

      Sofascore.apply_racing_roster()
      second = Sofascore.list_by_team(@racing) |> Enum.map(&{&1.jersey_number, &1.name}) |> Enum.sort()

      assert first == second
      assert length(first) == 32

      official = RacingRoster.players() |> Enum.map(&{&1.number, &1.name}) |> Enum.sort()
      assert first == official
    end
    test "compound surnames and overrides become the pitch short label" do
      seed(%{sofascore_id: "1017460", name: "Marco Di Cesare", jersey_number: 3, position: "Defensor"})

      Sofascore.apply_racing_roster()

      di = Repo.get_by!(SofascorePlayer, jersey_number: 3)
      assert di.short_name == "Di Cesare"

      sosa = Repo.get_by!(SofascorePlayer, jersey_number: 13)
      assert sosa.short_name == "S. Sosa"
    end
  end
end
