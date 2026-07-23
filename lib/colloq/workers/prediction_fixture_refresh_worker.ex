defmodule Colloq.Workers.PredictionFixtureRefreshWorker do
  @moduledoc """
  Daily check (08:00 Argentina / 11:00 UTC) for newly-published league fixtures.

  Sofascore releases the tournament a few fechas at a time, so the Prode can
  only show the rounds scheduled so far. This worker force-refreshes the
  round-fixtures cache for the current fecha and the next several, so a fecha
  scheduled since yesterday is picked up promptly, and logs which fechas are now
  defined. Read-only apart from warming the cache; safe to re-run.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  alias Colloq.Sofascore

  require Logger

  # How many rounds past the current fecha to look ahead — comfortably more than
  # the ~3 Sofascore tends to publish in advance, so a newly-added one is caught.
  @lookahead 6

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Sofascore.current_season_id() do
      nil ->
        Logger.info("[FixtureRefresh] sin temporada configurada — nada que revisar")
        :ok

      season ->
        current = Sofascore.current_round()
        rounds = for r <- current..(current + @lookahead), r >= 1, do: r

        # Bust the cache first so we see fixtures published since the last run
        # rather than a stale 10-minute copy; `round_defined?/1` then re-fetches
        # and re-warms each round.
        Enum.each(rounds, fn r ->
          Cachex.del(:forum_cache, "sofascore:round:#{season}:#{r}")
        end)

        defined = Enum.filter(rounds, &Sofascore.round_defined?/1)

        Logger.info(
          "[FixtureRefresh] temporada #{season}: fechas definidas #{inspect(defined)} " <>
            "(revisadas #{inspect(rounds)}, fecha actual #{current})"
        )

        :ok
    end
  end
end
