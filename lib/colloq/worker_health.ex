defmodule Colloq.WorkerHealth do
  @moduledoc """
  Background job health, read straight from `oban_jobs`.

  Oban telemetry already feeds LiveDashboard, but those metrics live in memory
  and only exist while you are watching. Every worker failure this project has
  hit was silent in exactly that gap: the LLM responder discarding jobs on an
  HTTP 404, the fixture digest raising on every run, the score bot never having
  executed at all. None of them surfaced anywhere an admin would look.

  These functions read persisted state instead, so a job that died overnight is
  still visible in the morning.
  """
  import Ecto.Query

  alias Colloq.Repo

  # Oban prunes completed jobs (7 days here), so "completed" counts are a recent
  # window, not all time. Failures are what matter and they stay put.
  @states ~w(available scheduled executing retryable completed discarded cancelled)

  @doc """
  Per-worker job counts by state, worst first.

  Sorted by discarded then retryable, so a worker that is failing sits at the
  top rather than being buried under whichever one is busiest.
  """
  def by_worker(opts \\ []) do
    since = Keyword.get(opts, :since, hours_ago(24))

    from(j in "oban_jobs",
      where: j.inserted_at >= ^since,
      group_by: [j.worker, j.state],
      select: {j.worker, j.state, count(j.id)}
    )
    |> Repo.all()
    |> Enum.group_by(fn {worker, _, _} -> worker end)
    |> Enum.map(fn {worker, rows} ->
      counts = Map.new(rows, fn {_, state, n} -> {state, n} end)

      %{
        worker: short_name(worker),
        module: worker,
        total: counts |> Map.values() |> Enum.sum(),
        discarded: Map.get(counts, "discarded", 0),
        retryable: Map.get(counts, "retryable", 0),
        executing: Map.get(counts, "executing", 0),
        pending: Map.get(counts, "available", 0) + Map.get(counts, "scheduled", 0),
        completed: Map.get(counts, "completed", 0),
        cancelled: Map.get(counts, "cancelled", 0)
      }
    end)
    |> Enum.sort_by(&{-&1.discarded, -&1.retryable, -&1.total})
  end

  @doc """
  Recent jobs that gave up, with the error that killed them.

  `discarded` means Oban exhausted `max_attempts` — nobody is retrying it and
  the work is simply lost, which is the state worth showing an admin.
  """
  def recent_failures(limit \\ 8) do
    from(j in "oban_jobs",
      where: j.state == "discarded",
      order_by: [desc: j.discarded_at],
      limit: ^limit,
      select: %{
        id: j.id,
        worker: j.worker,
        args: j.args,
        errors: j.errors,
        attempt: j.attempt,
        discarded_at: j.discarded_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn job ->
      %{
        id: job.id,
        worker: short_name(job.worker),
        args: summarize_args(job.args),
        attempt: job.attempt,
        at: job.discarded_at,
        error: last_error(job.errors)
      }
    end)
  end

  @doc "Totals across every worker, for the summary tiles."
  def totals(opts \\ []) do
    rows = by_worker(opts)

    %{
      workers: length(rows),
      discarded: Enum.sum(Enum.map(rows, & &1.discarded)),
      retryable: Enum.sum(Enum.map(rows, & &1.retryable)),
      pending: Enum.sum(Enum.map(rows, & &1.pending)),
      completed: Enum.sum(Enum.map(rows, & &1.completed))
    }
  end

  @doc "Workers that exist in the codebase but have no job rows in the window."
  def states, do: @states

  # "Elixir.Colloq.Workers.ScoreBotWorker" -> "ScoreBotWorker"
  defp short_name(worker) when is_binary(worker) do
    worker |> String.split(".") |> List.last()
  end

  defp short_name(other), do: to_string(other)

  # Oban stores errors as a list of maps; the last one is why it gave up. The
  # stored string is a full formatted exception, so keep the first line.
  defp last_error(errors) when is_list(errors) and errors != [] do
    errors
    |> List.last()
    |> case do
      %{"error" => error} when is_binary(error) -> first_line(error)
      other -> other |> inspect() |> first_line()
    end
  end

  defp last_error(_), do: nil

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end

  # Args are arbitrary; show the identifying keys rather than a JSON blob.
  defp summarize_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v) |> String.slice(0, 40)}" end)
    |> Enum.sort()
    |> Enum.join(" ")
    |> String.slice(0, 120)
  end

  defp summarize_args(_), do: ""

  # NaiveDateTime, not DateTime: oban_jobs stores naive UTC timestamps, and
  # going through DateTime would drag in the timezone database for a comparison
  # that needs no timezone at all — which then raises during the window before
  # tzdata finishes loading its table at boot.
  defp hours_ago(n), do: NaiveDateTime.utc_now() |> NaiveDateTime.add(-n * 3600, :second)
end
