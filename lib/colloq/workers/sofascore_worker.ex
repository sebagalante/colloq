defmodule Colloq.Workers.SofascoreWorker do
  @moduledoc """
  Sofascore API integration worker.

  Supports multiple actions in a single worker:
    - fetch_fixtures: fetches upcoming matches and caches for 12h
    - fetch_lineups: fetches lineups and broadcasts via PubSub
    - fetch_stats: fetches player stats and caches
    - fetch_standings: fetches league standings and caches for 12h

  Adds random jitter of 500-1500ms between consecutive calls
  to avoid overloading the API.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  require Logger

  @user_agent "Colloq/1.0"

  defp base_url, do: Application.get_env(:colloq, :sofascore_api_url, "https://www.sofascore.com/api/v1")

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "fetch_fixtures", "team_id" => team_id}}) do
    Logger.info("[Sofascore] Obteniendo próximos fixtures para team #{team_id}")

    case api_get("/team/#{team_id}/events/next/0") do
      {:ok, %{"events" => events}} ->
        Cachex.put(:forum_cache, "sofascore:fixtures:#{team_id}", events, ttl: :timer.hours(12))
        {:ok, "fixtures actualizados: #{length(events)}"}

      {:error, reason} ->
        Logger.error("[Sofascore] Error fetch_fixtures team #{team_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "fetch_fixtures"}}) do
    # No team_id: fetches fixtures for all teams with registered players
    team_ids =
      Colloq.Sofascore.teams_with_players()
      |> Enum.map(& &1.id)

    results =
      Enum.map(team_ids, fn team_id ->
        jitter()
        perform(%Oban.Job{args: %{"action" => "fetch_fixtures", "team_id" => team_id}})
      end)

    {:ok, "#{length(results)} equipos actualizados"}
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
  def perform(%Oban.Job{args: %{"action" => "fetch_squad", "team_id" => team_id}}) do
    Logger.info("[Sofascore] Obteniendo plantilla team #{team_id}")

    case Colloq.Sofascore.fetch_and_seed_squad(team_id) do
      {:ok, count} ->
        Logger.info("[Sofascore] Plantilla team #{team_id}: #{count} jugadores")
        {:ok, "squad team #{team_id}: #{count} jugadores"}

      {:error, reason} ->
        Logger.error("[Sofascore] Error fetch_squad team #{team_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "fetch_squad"}}) do
    # No team_id: fetches squads for all known teams
    {:ok, results} = Colloq.Sofascore.fetch_and_seed_all(force: true)

    Enum.each(results, fn
      {team, {:ok, count}} -> Logger.info("[Sofascore] #{team}: #{count} jugadores")
      {team, {:error, reason}} -> Logger.warning("[Sofascore] #{team}: #{inspect(reason)}")
      {team, :skipped} -> :ok
    end)

    {:ok, "fetch_squad completado"}
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
    url = "#{base_url()}#{path}"

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
