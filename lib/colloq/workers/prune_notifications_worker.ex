defmodule Colloq.Workers.PruneNotificationsWorker do
  @moduledoc """
  Worker de limpieza de notificaciones antiguas.

  Se ejecuta vía Oban Cron o puede ser disparado por una regla de automatización.
  Elimina notificaciones con más de 90 días de antigüedad.
  Un solo intento: no reintentar si falla.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Colloq.Notifications

  @impl Oban.Worker
  def perform(_job) do
    deleted = Notifications.delete_old_notifications(90)

    {:ok, deleted: deleted}
  end
end
