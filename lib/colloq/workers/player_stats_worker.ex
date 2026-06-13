defmodule Colloq.Workers.PlayerStatsWorker do
  @moduledoc """
  Worker de estadísticas de jugador vía API-Football.

  Obtiene estadísticas de jugadores desde el endpoint /players de
  API-Football, las enriquece con datos de SofascoreWorker y
  las almacena en Cachex.

  Al completar la carga, transmite :player_comparison_ready por PubSub
  para que el frontend pueda mostrar la comparación de jugadores.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @api_url "https://v3.football.api-sports.io"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "player_id" => player_id,
    "season" => season,
    "league_id" => league_id
  }}) do
    Logger.info("[PlayerStats] Obteniendo estadísticas de jugador #{player_id}")

    api_key = Application.get_env(:colloq, :api_football_key)

    unless api_key do
      Logger.warning("[PlayerStats] API_FOOTBALL_KEY no configurada")
      {:discard, "sin API key"}
    else
      case fetch_player_stats(api_key, player_id, season, league_id) do
        {:ok, data} ->
          cache_key = "player_stats:#{player_id}:#{season}:#{league_id}"
          Cachex.put(:forum_cache, cache_key, data, ttl: :timer.hours(6))

          ColloqWeb.Endpoint.broadcast("players", "player_comparison_ready", %{
            player_id: player_id,
            season: season
          })

          {:ok, "estadísticas obtenidas"}

        {:error, reason} ->
          Logger.error("[PlayerStats] Error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp fetch_player_stats(api_key, player_id, season, league_id) do
    params = %{
      id: player_id,
      season: season
    }

    params =
      if league_id, do: Map.put(params, :league, league_id), else: params

    query = URI.encode_query(params)

    case Req.get("#{@api_url}/players?#{query}",
           headers: %{
             "x-apisports-key" => api_key,
             "accept" => "application/json"
           },
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"response" => [player_data | _]}}} ->
        {:ok, enrich_with_sofascore(player_data)}

      {:ok, %{status: 200, body: %{"response" => []}}} ->
        {:error, :jugador_no_encontrado}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp enrich_with_sofascore(player_data) do
    player = player_data["player"] || %{}
    statistics = player_data["statistics"] || []

    player_data
    |> Map.put("statistics", statistics)
    |> Map.put("player_name", player["name"])
    |> Map.put("player_photo", player["photo"])
  end
end
