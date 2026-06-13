defmodule Colloq.Workers.SofascoreWorker do
  @moduledoc """
  Worker de integración con la API de Sofascore.

  Soporta múltiples acciones en un solo worker:
    - fetch_fixtures: obtiene próximos partidos y cachea 12h
    - fetch_lineups: obtiene formaciones y transmite por PubSub
    - fetch_stats: obtiene estadísticas de jugador y cachea
    - fetch_standings: obtiene tabla de posiciones y cachea 12h

  Agrega jitter aleatorio de 500-1500ms entre llamadas consecutivas
  para no sobrecargar la API.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  require Logger

  @base_url "https://www.sofascore.com/api/v1"
  @user_agent "Colloq/1.0"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "fetch_fixtures"}}) do
    Logger.info("[Sofascore] Obteniendo próximos fixtures")

    case api_get("/team/3215/events/next/0") do
      {:ok, %{"events" => events}} ->
        Cachex.put(:forum_cache, "sofascore:fixtures", events, ttl: :timer.hours(12))
        {:ok, "fixtures actualizados: #{length(events)}"}

      {:error, reason} ->
        Logger.error("[Sofascore] Error fetch_fixtures: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "fetch_lineups", "event_id" => event_id}}) do
    Logger.info("[Sofascore] Obteniendo formaciones para evento #{event_id}")

    jitter()

    case api_get("/event/#{event_id}/lineups") do
      {:ok, data} ->
        Cachex.put(:forum_cache, "sofascore:lineups:#{event_id}", data, ttl: :timer.hours(4))
        ColloqWeb.Endpoint.broadcast("match:#{event_id}", "lineups_confirmed", data)
        {:ok, "formaciones obtenidas"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "action" => "fetch_stats",
    "player_id" => player_id,
    "season_id" => season_id,
    "status" => status
  }}) do
    Logger.info("[Sofascore] Estadísticas jugador #{player_id} temporada #{season_id}")

    jitter()

    case api_get("/player/#{player_id}/unique-tournament/155/season/#{season_id}/statistics/overall") do
      {:ok, data} ->
        ttl = if status == "finished", do: :timer.hours(24 * 30), else: :timer.hours(6)
        Cachex.put(:forum_cache, "sofascore:stats:#{player_id}:#{season_id}", data, ttl: ttl)
        {:ok, "estadísticas guardadas"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "fetch_standings", "season_id" => season_id}}) do
    Logger.info("[Sofascore] Obteniendo tabla de posiciones temporada #{season_id}")

    case api_get("/unique-tournament/155/season/#{season_id}/standings/total") do
      {:ok, data} ->
        Cachex.put(:forum_cache, "sofascore:standings:#{season_id}", data, ttl: :timer.hours(12))
        {:ok, "tabla guardada"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_get(path) do
    url = "#{@base_url}#{path}"

    case Req.get(url,
           headers: %{
             "user-agent" => @user_agent,
             "accept" => "application/json"
           },
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        Logger.warning("[Sofascore] Status #{status} para #{path}")
        {:error, {:http_error, status}}

      {:error, error} ->
        Logger.warning("[Sofascore] Error HTTP: #{inspect(error)}")
        {:error, error}
    end
  end

  defp jitter do
    ms = :rand.uniform(1000) + 500
    Process.sleep(ms)
  end
end
