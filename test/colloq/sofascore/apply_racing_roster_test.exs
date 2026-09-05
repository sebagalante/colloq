defmodule Colloq.Sofascore.ApplyRacingRosterTest do
  use Colloq.DataCase, async: true

  alias Colloq.Sofascore
  alias Colloq.Sofascore.SofascorePlayer

  @racing Sofascore.racing_team_id()
  @newells 3212

  # A stand-in for what OfficialRoster.fetch/1 scrapes, so these tests exercise
  # the reconcile without touching the club's site.
  @official [
    %{number: 1, name: "Francisco Gómez", surname: "Gómez", position: "Arquero"},
    %{number: 2, name: "Matías Damián Pérez", surname: "Pérez", position: "Defensor", short: "M. Pérez"},
    %{number: 3, name: "Marco Genaro Di Cesare", surname: "Di Cesare", position: "Defensor"},
    %{number: 12, name: "Thiago De Bellis", surname: "De Bellis", position: "Arquero"},
    %{number: 28, name: "Santiago Germán Solari", surname: "Solari", position: "Delantero"},
    %{number: 32, name: "Lautaro Ariel Diaz", surname: "Diaz", position: "Delantero"},
    %{number: 33, name: "Leonel Ulises Pérez", surname: "Pérez", position: "Mediocampista", short: "L. Pérez"}
  ]

  defp seed(attrs) do
    %SofascorePlayer{}
    |> SofascorePlayer.changeset(Map.merge(%{team_id: @racing}, attrs))
    |> Repo.insert!()
  end

  defp apply_roster, do: Sofascore.apply_racing_roster(@official)

  test "matches an existing row by name and keeps its sofascore_id" do
    # Sofascore had the wrong number and a shorter name.
    seed(%{sofascore_id: "992093", name: "Lautaro Díaz", jersey_number: 19, position: "Delantero"})

    apply_roster()

    row = Repo.get_by!(SofascorePlayer, sofascore_id: "992093")
    assert row.jersey_number == 32
    assert row.name == "Lautaro Ariel Diaz"
  end

  test "inserts an official player absent from the stored squad" do
    apply_roster()

    # De Bellis isn't seeded here, so he must be created with a synthetic id.
    row = Repo.get_by!(SofascorePlayer, jersey_number: 12)
    assert row.name == "Thiago De Bellis"
    assert row.sofascore_id == "racing-official-12"
  end

  test "removes a stored player not on the official list" do
    seed(%{sofascore_id: "1177565", name: "Damián Pizarro", jersey_number: 14, position: "Delantero"})

    apply_roster()

    refute Repo.get_by(SofascorePlayer, sofascore_id: "1177565")
  end

  test "two players sharing a surname keep their own sofascore_id" do
    seed(%{sofascore_id: "989208", name: "Matías Pérez", jersey_number: 2, position: "Defensor"})
    seed(%{sofascore_id: "1471214", name: "Leonel Pérez", jersey_number: 33, position: "Mediocampista"})

    apply_roster()

    # Greedy surname-only matching used to hand #2 the other Pérez's id.
    assert Repo.get_by!(SofascorePlayer, sofascore_id: "989208").jersey_number == 2
    assert Repo.get_by!(SofascorePlayer, sofascore_id: "1471214").jersey_number == 33
  end

  test "reclaims a signing Sofascore still lists at his former club" do
    seed(%{sofascore_id: "1104323", name: "Santiago Solari", jersey_number: 28, position: "Delantero", team_id: @newells})

    apply_roster()

    row = Repo.get_by!(SofascorePlayer, sofascore_id: "1104323")
    assert row.team_id == @racing
    assert row.jersey_number == 28
    # No synthetic duplicate alongside the real, photo-bearing row.
    refute Repo.get_by(SofascorePlayer, sofascore_id: "racing-official-28")
  end

  test "leaves a same-surname player at another club alone" do
    seed(%{sofascore_id: "555000", name: "Joaquín Pérez", jersey_number: 7, position: "Delantero", team_id: @newells})

    apply_roster()

    assert Repo.get_by!(SofascorePlayer, sofascore_id: "555000").team_id == @newells
  end

  test "leaves the squad matching the official list exactly, and is idempotent" do
    apply_roster()
    first = Sofascore.list_by_team(@racing) |> Enum.map(&{&1.jersey_number, &1.name}) |> Enum.sort()

    apply_roster()
    second = Sofascore.list_by_team(@racing) |> Enum.map(&{&1.jersey_number, &1.name}) |> Enum.sort()

    assert first == second
    assert first == @official |> Enum.map(&{&1.number, &1.name}) |> Enum.sort()
  end

  test "compound surnames and clash overrides become the pitch short label" do
    seed(%{sofascore_id: "1017460", name: "Marco Di Cesare", jersey_number: 3, position: "Defensor"})

    apply_roster()

    assert Repo.get_by!(SofascorePlayer, jersey_number: 3).short_name == "Di Cesare"
    assert Repo.get_by!(SofascorePlayer, jersey_number: 33).short_name == "L. Pérez"
  end
end
