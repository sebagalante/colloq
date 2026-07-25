defmodule Colloq.Workers.PruneDraftsWorker do
  @moduledoc """
  Post draft cleanup worker. Runs nightly (see the Oban crontab).

  Deletes drafts untouched for 7 days. Keyed on `updated_at`, not
  `inserted_at`: a draft someone keeps coming back to and editing is the last
  one to throw away, and dating it from first save deleted exactly those.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Colloq.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.utc_now() |> DateTime.add(-7, :day)

    {deleted, _} =
      Repo.delete_all(
        Ecto.Query.from(
          d in "post_drafts",
          where: d.updated_at < ^cutoff
        )
      )

    {:ok, deleted: deleted}
  end
end
