defmodule Colloq.Workers.NotificationWorker do
  @moduledoc """
  Worker de envío de emails de notificación.

  Se encola cada vez que se crea una notificación.
  Carga la notificación y el usuario destinatario.
  Si el usuario tiene notificaciones habilitadas, envía el email vía Swoosh.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Accounts
  alias Colloq.Notifications.Notification
  alias Colloq.Mailer
  import Swoosh.Email

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    notification = Repo.get!(Notification, notification_id) |> Repo.preload(:user)
    user = notification.user

    if user.notifications_enabled do
      notification
      |> build_email(user)
      |> Mailer.deliver()

      notification
      |> Ecto.Changeset.change(email_sent: true, email_sent_at: DateTime.utc_now())
      |> Repo.update!()
    end

    :ok
  end

  defp build_email(notification, user) do
    new()
    |> to({user.display_name || user.username, user.email})
    |> from({"Colloq", "no-reply@colloq.ar"})
    |> subject("[Colloq] #{notification.title}")
    |> html_body(email_body(notification))
    |> text_body(notification.body)
  end

  defp email_body(notification) do
    data = notification.data || %{}

    """
    <div style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>#{notification.title}</h2>
      <p>#{notification.body}</p>
      #{link_section(data)}
      <hr />
      <p style="color: #888; font-size: 12px;">
        Recibiste este correo porque tenés las notificaciones habilitadas en Colloq.
        Podés desactivarlas desde tu perfil.
      </p>
    </div>
    """
  end

  defp link_section(%{"topic_id" => topic_id, "post_id" => post_id}) do
    url = "/t/#{topic_id}##{post_id}"
    "<p><a href=\"#{url}\">Ver en Colloq</a></p>"
  end

  defp link_section(%{"topic_id" => topic_id}) do
    "<p><a href=\"/t/#{topic_id}\">Ver en Colloq</a></p>"
  end

  defp link_section(_), do: ""
end
