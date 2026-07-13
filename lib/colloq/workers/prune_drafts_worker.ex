defmodule Colloq.Workers.PruneDraftsWorker do
  @moduledoc """
  Post draft cleanup worker.

  Deletes drafts older than 7 days
  via a direct SQL query on the post_drafts table.
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
          where: d.inserted_at < ^cutoff
        )
      )

    {:ok, deleted: deleted}
  end
end
