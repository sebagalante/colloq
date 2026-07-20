defmodule Colloq.Workers.AutomationSchedulerWorker do
  @moduledoc """
  Fires recurring automations on their configured interval.

  Runs once a minute (Oban cron). For every enabled `recurring` automation it
  enqueues an `AutomationWorker` job, using Oban uniqueness keyed on the
  automation id with a `period` equal to the automation's interval — so an
  automation set to "every 5 minutes" is actually enqueued at most once per
  5 minutes even though this scheduler ticks every minute.

  The interval comes from the automation's `trigger_config`:

      {"interval_minutes": 5}

  defaulting to 5 minutes, floored at 1.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  require Logger

  alias Colloq.Automations
  alias Colloq.Workers.AutomationWorker

  @default_interval_minutes 5

  @impl Oban.Worker
  def perform(_job) do
    for automation <- Automations.list_enabled_recurring() do
      period = interval_seconds(automation)

      %{automation_id: automation.id, trigger: "recurring"}
      |> AutomationWorker.new(
        unique: [
          period: period,
          keys: [:automation_id],
          states: [:available, :scheduled, :executing, :retryable, :completed]
        ]
      )
      |> Oban.insert()
    end

    :ok
  end

  defp interval_seconds(automation) do
    minutes =
      case Map.get(automation.trigger_config || %{}, "interval_minutes") do
        n when is_integer(n) and n > 0 -> n
        n when is_binary(n) -> parse_minutes(n)
        _ -> @default_interval_minutes
      end

    max(minutes, 1) * 60
  end

  defp parse_minutes(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> @default_interval_minutes
    end
  end
end
