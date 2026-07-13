defmodule Colloq.Sofascore do
  @moduledoc """
  Sofascore player context.

  Manages the local database of Sofascore player IDs for querying
  stats, lineups, and other match data.

  Supports multiple teams from the Argentine league and other competitions.
  Squads are fetched dynamically from the Sofascore API
  (/team/{id}/players endpoint) and cached locally in the database.
  """

  require Logger

  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Sofascore.SofascorePlayer

  @user_agent "Colloq/1.0"

  defp api_base, do: Application.get_env(:colloq, :sofascore_api_url, "https://www.sofascore.com/api/v1")

  # Maps Sofascore API position codes to Spanish labels
  @position_map %{
    "G" => "Arquero",
    "D" => "Defensor",
    "M" => "Mediocampista",
    "F" => "Delantero"
  }

  # ===========================================================================
  # Known teams registry
  # ===========================================================================

  @teams %{
    racing: %{id: 174, name: "Racing Club", short: "RAC"},
    river: %{id: 95, name: "River Plate", short: "RIV"},
    boca: %{id: 94, name: "Boca Juniors", short: "BOC"},
    independiente: %{id: 96, name: "Independiente", short: "IND"},
    san_lorenzo: %{id: 97, name: "San Lorenzo", short: "SLO"},
    estudiantes: %{id: 98, name: "Estudiantes", short: "EST"},
    lanus: %{id: 102, name: "Lanús", short: "LAN"},
    argentinos: %{id: 101, name: "Argentinos Juniors", short: "ARJ"},
    talleres: %{id: 113, name: "Talleres", short: "TAL"},
    rosario_central: %{id: 110, name: "Rosario Central", short: "ROC"},
    newells: %{id: 109, name: "Newell's Old Boys", short: "NOB"},
    velez: %{id: 100, name: "Vélez Sarsfield", short: "VEL"}
  }

  @doc """
  Returns the known teams map with their Sofascore IDs.
  """
  def teams, do: @teams

  @doc """
  Returns team info by atom key (e.g. :racing, :river).
  """
  def team_info(key) when is_atom(key), do: Map.get(@teams, key)

  @doc """
  Returns the team atom key from a Sofascore team_id.
  """
  def team_key_by_id(team_id) do
    Enum.find_value(@teams, fn {key, %{id: id}} ->
      if id == team_id, do: key
    end)
  end

  # ===========================================================================
  # Queries
  # ===========================================================================

  @doc """
  Gets a player by their Sofascore ID. Raises if not found.
  """
  def get_player!(sofascore_id) do
    Repo.get_by!(SofascorePlayer, sofascore_id: sofascore_id)
  end

  @doc """
  Gets a player by their Sofascore ID. Returns nil if not found.
  """
  def get_player(sofascore_id) do
    Repo.get_by(SofascorePlayer, sofascore_id: sofascore_id)
  end

  @doc """
  Searches players by name (ILIKE search).
  """
  def search(query) when is_binary(query) and query != "" do
    search_term = "%#{query}%"

    SofascorePlayer
    |> where([p], ilike(p.name, ^search_term))
    |> order_by(:name)
    |> limit(20)
    |> Repo.all()
  end

  def search(_), do: []

  @doc """
  Lists all players for a team by Sofascore team_id.
  """
  def list_by_team(team_id) when is_integer(team_id) do
    SofascorePlayer
    |> where([p], p.team_id == ^team_id)
    |> order_by([p], [p.position, p.name])
    |> Repo.all()
  end

  @doc """
  Lists all players for a team by atom key.
  """
  def list_by_team(team_key) when is_atom(team_key) do
    case team_info(team_key) do
      %{id: id} -> list_by_team(id)
      nil -> []
    end
  end

  @doc """
  Lists players for a team filtered by position.

  Positions: "Arquero", "Defensor", "Mediocampista", "Delantero"
  """
  def list_by_team_and_position(team_id, position)
      when is_integer(team_id) and is_binary(position) do
    SofascorePlayer
    |> where([p], p.team_id == ^team_id and p.position == ^position)
    |> order_by(:name)
    |> Repo.all()
  end

  def list_by_team_and_position(team_key, position) when is_atom(team_key) do
    case team_info(team_key) do
      %{id: id} -> list_by_team_and_position(id, position)
      nil -> []
    end
  end

  @doc """
  Counts how many players are registered for a team.
  """
  def count_by_team(team_id) when is_integer(team_id) do
    SofascorePlayer
    |> where([p], p.team_id == ^team_id)
    |> Repo.aggregate(:count, :id)
  end

  def count_by_team(team_key) when is_atom(team_key) do
    case team_info(team_key) do
      %{id: id} -> count_by_team(id)
      nil -> 0
    end
  end

  @doc """
  Lists all teams that have registered players.
  """
  def teams_with_players do
    SofascorePlayer
    |> select([p], p.team_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.map(fn team_id ->
      case team_key_by_id(team_id) do
        nil -> %{id: team_id, name: "Team #{team_id}", key: nil}
        key -> %{id: team_id, name: @teams[key].name, key: key}
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  # ===========================================================================
  # Fetch from Sofascore API
  # ===========================================================================

  @doc """
  Fetches a team's squad from the Sofascore API and upserts into the local DB.
  Updates names and positions if the player already exists.

  Accepts a team atom key (:racing, :river, etc.) or a numeric team_id.

  Returns {:ok, count} or {:error, reason}.
  """
  def fetch_and_seed_squad(team_key) when is_atom(team_key) do
    %{id: id} = team_info(team_key)
    fetch_and_seed_squad(id)
  end

  def fetch_and_seed_squad(team_id) when is_integer(team_id) do
    case fetch_team_players(team_id) do
      {:ok, players} ->
        seed_squad(team_id, players)

      {:error, :not_found} ->
        Logger.warning("[Sofascore] Team #{team_id} not found in API")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[Sofascore] Error fetching squad team #{team_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches squads for all known teams and seeds them into the local DB.

  Returns {:ok, results} where results is a list of {team_key, result}.
  Teams that already have players in the DB are skipped unless force: true.
  """
  def fetch_and_seed_all(opts \\ []) do
    force = Keyword.get(opts, :force, false)

    results =
      @teams
      |> Enum.map(fn {key, _info} ->
        if not force and count_by_team(key) > 0 do
          {key, :skipped}
        else
          # Rate limiting: random delay between requests
          Process.sleep(:rand.uniform(1000) + 500)
          {key, fetch_and_seed_squad(key)}
        end
      end)

    {:ok, results}
  end

  @doc """
  Calls the Sofascore /team/{id}/players endpoint and parses the response
  into a list of maps compatible with seed_squad/2.

  Returns {:ok, players} or {:error, reason}.
  """
  def fetch_team_players(team_id) when is_integer(team_id) do
    case Req.get("#{api_base()}/team/#{team_id}/players",
           headers: %{
             "user-agent" => @user_agent,
             "accept" => "application/json"
           },
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"players" => raw_players}}} ->
        players =
          raw_players
          |> Enum.map(&parse_api_player/1)
          |> Enum.filter(&(&1 != nil))

        {:ok, players}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parses a player from the Sofascore API format.
  # Response shape: %{"player" => %{...}}.
  defp parse_api_player(%{"player" => player_data}) do
    %{
      sofascore_id: to_string(player_data["id"]),
      name: player_data["name"],
      position: translate_position(player_data["position"]),
      photo_url: player_data["photoUrl"]
    }
  end

  defp parse_api_player(_), do: nil

  defp translate_position(code) when is_binary(code), do: Map.get(@position_map, code, code)
  defp translate_position(_), do: nil

  # ===========================================================================
  # Seeding (from already-fetched data)
  # ===========================================================================

  @doc """
  Inserts or updates a team's squad from a list of player maps.

  Accepts a team atom key (:racing, :river, etc.) or a numeric team_id,
  along with a list of maps containing: sofascore_id, name, position, photo_url (optional).
  """
  def seed_squad(team_key, players) when is_atom(team_key) and is_list(players) do
    %{id: team_id} = team_info(team_key)
    seed_squad(team_id, players)
  end

  def seed_squad(team_id, players) when is_integer(team_id) and is_list(players) do
    players = Enum.map(players, &Map.put(&1, :team_id, team_id))

    Repo.transaction(fn ->
      Enum.each(players, fn attrs ->
        %SofascorePlayer{}
        |> SofascorePlayer.changeset(attrs)
        |> Repo.insert!(
          on_conflict: [
            set: [
              name: attrs[:name] || attrs["name"],
              position: attrs[:position] || attrs["position"],
              photo_url: attrs[:photo_url] || attrs["photo_url"],
              team_id: team_id
            ]
          ],
          conflict_target: :sofascore_id
        )
      end)
    end)

    {:ok, length(players)}
  end
end
