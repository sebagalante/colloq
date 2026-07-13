defmodule Colloq.Workers.PruneNotificationsWorker do
  @moduledoc """
  Stale notification cleanup worker.

  Runs via Oban Cron or can be triggered by an automation rule.
  Deletes notifications older than 90 days.
  Single attempt: no retries on failure.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Colloq.Notifications

  @impl Oban.Worker
  def perform(_job) do
    deleted = Notifications.delete_old_notifications(90)

    {:ok, deleted: deleted}
  end
end
