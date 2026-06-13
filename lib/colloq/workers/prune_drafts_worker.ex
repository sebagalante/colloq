defmodule Colloq.Workers.PruneDraftsWorker do
  @moduledoc """
  Worker de limpieza de borradores de posts.

  Elimina borradores con más de 7 días de antigüedad
  mediante una consulta SQL directa a la tabla post_drafts.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Colloq.Repo

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
