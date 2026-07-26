defmodule Colloq.Workers.InviteWorker do
  @moduledoc """
  Invitation email delivery worker.

  Mirrors `Colloq.Workers.PasswordResetWorker`: the invite row owns the token and
  its expiry, this worker only renders and sends the link. An invite that was
  revoked or already accepted between queueing and running is skipped rather
  than retried.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Colloq.Accounts.Invite
  alias Colloq.Invites
  alias Colloq.Mailer
  alias Colloq.Repo

  import Swoosh.Email

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invite_id" => invite_id}}) do
    case Repo.get(Invite, invite_id) do
      nil ->
        Logger.info("[Invite] #{invite_id} ya no existe — no se envía")
        :ok

      invite ->
        if Invite.pending?(invite), do: deliver(invite), else: :ok
    end
  end

  defp deliver(invite) do
    url = signup_url(invite.token)

    new()
    |> to({nil, invite.email})
    |> from({"Colloq", "no-reply@colloq.ar"})
    |> subject("[Colloq] Te invitaron a sumarte")
    |> html_body(email_html(url, invite.expires_at))
    |> text_body(email_text(url, invite.expires_at))
    |> Mailer.deliver()

    Invites.mark_sent(invite)
    :ok
  end

  defp signup_url(token) do
    base_url = Application.get_env(:colloq, :base_url, "https://colloq.ar")
    "#{base_url}/register?invite=#{token}"
  end

  defp expiry_label(expires_at), do: Calendar.strftime(expires_at, "%d/%m/%Y")

  defp email_html(url, expires_at) do
    """
    <div style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Te invitaron a Colloq</h2>
      <p>Colloq es la comunidad de Racing Club de Avellaneda. Alguien te invitó a crear tu cuenta.</p>
      <p style="margin: 24px 0;">
        <a href="#{url}" style="background-color: #3b82f6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;">
          Crear mi cuenta
        </a>
      </p>
      <p style="color: #666; font-size: 14px;">
        Esta invitación vence el #{expiry_label(expires_at)} y sirve una sola vez.
      </p>
      <hr />
      <p style="color: #888; font-size: 12px;">
        Si no esperabas esta invitación, podés ignorar este email.
      </p>
    </div>
    """
  end

  defp email_text(url, expires_at) do
    """
    Te invitaron a Colloq

    Colloq es la comunidad de Racing Club de Avellaneda. Alguien te invitó a crear tu cuenta.

    Abrí el siguiente enlace para registrarte:
    #{url}

    Esta invitación vence el #{expiry_label(expires_at)} y sirve una sola vez.

    Si no esperabas esta invitación, podés ignorar este email.
    """
  end
end
