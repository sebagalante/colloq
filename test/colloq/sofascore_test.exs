defmodule Colloq.SofascoreTest do
  use Colloq.DataCase, async: true

  alias Colloq.Sofascore

  describe "teams/0" do
    test "returns a map of known teams" do
      teams = Sofascore.teams()

      assert Map.has_key?(teams, :racing)
      assert Map.has_key?(teams, :river)
      assert Map.has_key?(teams, :boca)

      assert %{id: 174, name: "Racing Club"} = teams[:racing]
    end
  end

  describe "team_info/1" do
    test "returns team info by key" do
      assert %{id: 174, name: "Racing Club"} = Sofascore.team_info(:racing)
    end

    test "returns nil for unknown key" do
      assert Sofascore.team_info(:nonexistent) == nil
    end
  end

  describe "team_key_by_id/1" do
    test "returns the key for a known team_id" do
      assert Sofascore.team_key_by_id(174) == :racing
    end

    test "returns nil for unknown team_id" do
      assert Sofascore.team_key_by_id(99999) == nil
    end
  end

  describe "seed_squad/2" do
    test "seeds players for a team by key" do
      players = [
        %{sofascore_id: "123", name: "Test Player", position: "Delantero"},
        %{sofascore_id: "456", name: "Another Player", position: "Arquero"}
      ]

      {:ok, 2} = Sofascore.seed_squad(:racing, players)

      assert Sofascore.count_by_team(:racing) == 2
    end

    test "seeds players for a team by id" do
      players = [
        %{sofascore_id: "789", name: "Test Player", position: "Mediocampista"}
      ]

      {:ok, 1} = Sofascore.seed_squad(174, players)

      assert Sofascore.count_by_team(174) == 1
    end

    test "upserts on conflict" do
      players = [%{sofascore_id: "123", name: "Old Name", position: "Defensor"}]
      {:ok, _} = Sofascore.seed_squad(:racing, players)

      updated = [%{sofascore_id: "123", name: "New Name", position: "Defensor"}]
      {:ok, _} = Sofascore.seed_squad(:racing, updated)

      assert Sofascore.count_by_team(:racing) == 1
      player = Sofascore.get_player("123")
      assert player.name == "New Name"
    end

    test "seeding different teams keeps them separate" do
      racing_players = [%{sofascore_id: "1", name: "Racing Player", position: "Delantero"}]
      river_players = [%{sofascore_id: "2", name: "River Player", position: "Arquero"}]

      {:ok, _} = Sofascore.seed_squad(:racing, racing_players)
      {:ok, _} = Sofascore.seed_squad(:river, river_players)

      assert Sofascore.count_by_team(:racing) == 1
      assert Sofascore.count_by_team(:river) == 1
    end

    test "stores photo_url when provided" do
      players = [
        %{
          sofascore_id: "123",
          name: "Test Player",
          position: "Delantero",
          photo_url: "https://example.com/photo.jpg"
        }
      ]

      {:ok, _} = Sofascore.seed_squad(:racing, players)

      player = Sofascore.get_player("123")
      assert player.photo_url == "https://example.com/photo.jpg"
    end
  end

  describe "list_by_team/1" do
    setup do
      {:ok, _} = Sofascore.seed_squad(:racing, [
        %{sofascore_id: "1", name: "Arias", position: "Arquero"},
        %{sofascore_id: "2", name: "Salas", position: "Delantero"},
        %{sofascore_id: "3", name: "Almendra", position: "Mediocampista"}
      ])
      :ok
    end

    test "lists players by team key" do
      players = Sofascore.list_by_team(:racing)
      assert length(players) == 3
    end

    test "lists players by team id" do
      players = Sofascore.list_by_team(174)
      assert length(players) == 3
    end

    test "returns empty list for unknown team key" do
      assert Sofascore.list_by_team(:nonexistent) == []
    end
  end

  describe "list_by_team_and_position/2" do
    setup do
      {:ok, _} = Sofascore.seed_squad(:racing, [
        %{sofascore_id: "1", name: "Arias", position: "Arquero"},
        %{sofascore_id: "2", name: "Salas", position: "Delantero"},
        %{sofascore_id: "3", name: "Martinez", position: "Delantero"}
      ])
      :ok
    end

    test "filters by position" do
      delanteros = Sofascore.list_by_team_and_position(:racing, "Delantero")
      assert length(delanteros) == 2
      arqueros = Sofascore.list_by_team_and_position(:racing, "Arquero")
      assert length(arqueros) == 1
    end
  end

  describe "search/1" do
    setup do
      {:ok, _} = Sofascore.seed_squad(:racing, [
        %{sofascore_id: "1", name: "Gabriel Arias", position: "Arquero"},
        %{sofascore_id: "2", name: "Maximiliano Salas", position: "Delantero"}
      ])
      :ok
    end

    test "finds players by partial name" do
      results = Sofascore.search("gabriel")
      assert length(results) == 1
      assert hd(results).name == "Gabriel Arias"
    end

    test "is case-insensitive" do
      results = Sofascore.search("SALAS")
      assert length(results) == 1
    end

    test "returns empty for empty query" do
      assert Sofascore.search("") == []
      assert Sofascore.search(nil) == []
    end
  end

  describe "get_player/1" do
    setup do
      {:ok, _} = Sofascore.seed_squad(:racing, [
        %{sofascore_id: "123", name: "Test Player", position: "Delantero"}
      ])
      :ok
    end

    test "returns player by sofascore_id" do
      player = Sofascore.get_player("123")
      assert player.name == "Test Player"
    end

    test "returns nil for unknown id" do
      assert Sofascore.get_player("nonexistent") == nil
    end
  end

  describe "get_player!/1" do
    setup do
      {:ok, _} = Sofascore.seed_squad(:racing, [
        %{sofascore_id: "123", name: "Test Player", position: "Delantero"}
      ])
      :ok
    end

    test "returns player by sofascore_id" do
      player = Sofascore.get_player!("123")
      assert player.name == "Test Player"
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Sofascore.get_player!("nonexistent")
      end
    end
  end

  describe "teams_with_players/0" do
    setup do
      {:ok, _} = Sofascore.seed_squad(:racing, [
        %{sofascore_id: "1", name: "Racing Player", position: "Delantero"}
      ])
      {:ok, _} = Sofascore.seed_squad(:river, [
        %{sofascore_id: "2", name: "River Player", position: "Arquero"}
      ])
      :ok
    end

    test "returns teams that have players" do
      teams = Sofascore.teams_with_players()
      team_names = Enum.map(teams, & &1.name)

      assert "Racing Club" in team_names
      assert "River Plate" in team_names
    end
  end

  # fetch_and_seed_squad/1 and fetch_team_players/1 hit the live Sofascore API
  # and are not tested here. They should be tested with Mox stubs in a
  # separate integration test file if network isolation is needed.
end
