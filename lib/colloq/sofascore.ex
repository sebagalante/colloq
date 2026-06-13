defmodule Colloq.Sofascore do
  @moduledoc """
  Contexto de jugadores de Sofascore.

  Gestiona la base local de IDs de jugadores de Racing Club
  vinculados a Sofascore para consultas de estadísticas, formaciones, etc.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Sofascore.SofascorePlayer

  @doc """
  Obtiene un jugador por su ID de Sofascore.
  """
  def get_player!(sofascore_id) do
    Repo.get_by!(SofascorePlayer, sofascore_id: sofascore_id)
  end

  @doc """
  Busca jugadores por nombre (búsqueda ILIKE).
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
  Inserta la plantilla completa de Racing Club 2026 en la base local.

  Estos IDs se usan para consultar estadísticas vía la API de Sofascore.
  """
  def seed_racing_squad do
    players = [
      %{sofascore_id: "890526", name: "Gabriel Arias", position: "Arquero", team_id: 174},
      %{sofascore_id: "1219905", name: "Facundo Cambeses", position: "Arquero", team_id: 174},
      %{sofascore_id: "1153235", name: "Juan Manuel Elordi", position: "Defensor", team_id: 174},
      %{sofascore_id: "871777", name: "Marco Di Cesare", position: "Defensor", team_id: 174},
      %{sofascore_id: "1126260", name: "Santiago Sosa", position: "Defensor", team_id: 174},
      %{sofascore_id: "1086592", name: "Nazareno Colombo", position: "Defensor", team_id: 174},
      %{sofascore_id: "1219915", name: "Santiago Quiros", position: "Defensor", team_id: 174},
      %{sofascore_id: "1142992", name: "Gaston Martirena", position: "Defensor", team_id: 174},
      %{sofascore_id: "1002181", name: "Gabriel Rojas", position: "Defensor", team_id: 174},
      %{sofascore_id: "1143884", name: "Agustin Garcia Basso", position: "Defensor", team_id: 174},
      %{sofascore_id: "1126231", name: "Agustin Almendra", position: "Mediocampista", team_id: 174},
      %{sofascore_id: "884996", name: "Juan Ignacio Nardoni", position: "Mediocampista", team_id: 174},
      %{sofascore_id: "1207147", name: "Baltasar Rodriguez", position: "Mediocampista", team_id: 174},
      %{sofascore_id: "995433", name: "Bruno Zuculini", position: "Mediocampista", team_id: 174},
      %{sofascore_id: "1066934", name: "Luciano Vietto", position: "Mediocampista", team_id: 174},
      %{sofascore_id: "1041653", name: "Maximiliano Salas", position: "Delantero", team_id: 174},
      %{sofascore_id: "929370", name: "Adrian Martinez", position: "Delantero", team_id: 174},
      %{sofascore_id: "1059125", name: "Roger Martinez", position: "Delantero", team_id: 174},
      %{sofascore_id: "1219927", name: "Agustin Ojeda", position: "Delantero", team_id: 174},
      %{sofascore_id: "1038000", name: "Johan Carbonero", position: "Delantero", team_id: 174}
    ]

    Repo.transaction(fn ->
      Enum.each(players, fn attrs ->
        %SofascorePlayer{}
        |> SofascorePlayer.changeset(attrs)
        |> Repo.insert!(
          on_conflict: [set: [name: attrs.name, position: attrs.position]],
          conflict_target: :sofascore_id
        )
      end)
    end)

    {:ok, length(players)}
  end
end
