defmodule Colloq.Workers.PasswordResetWorker do
  @moduledoc """
  Password reset email delivery worker.

  Generates a signed token with 1-hour expiration and sends
  a password reset email with the reset link.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Colloq.Mailer
  import Swoosh.Email

  @token_max_age :timer.hours(1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "email" => email, "token" => token}}) do
    reset_url = build_reset_url(token)

    new()
    |> to({nil, email})
    |> from({"Colloq", "no-reply@colloq.ar"})
    |> subject("[Colloq] Restablecer contraseña")
    |> html_body(email_html(reset_url))
    |> text_body(email_text(reset_url))
    |> Mailer.deliver()

    :ok
  end

  defp build_reset_url(token) do
    base_url = Application.get_env(:colloq, :base_url, "https://colloq.ar")
    "#{base_url}/reset-password?token=#{token}"
  end

  defp email_html(reset_url) do
    """
    <div style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Restablecer contraseña</h2>
      <p>Recibimos una solicitud para restablecer tu contraseña en Colloq.</p>
      <p>Hacé clic en el siguiente enlace para crear una nueva contraseña:</p>
      <p style="margin: 24px 0;">
        <a href="#{reset_url}" style="background-color: #3b82f6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;">
          Restablecer contraseña
        </a>
      </p>
      <p style="color: #666; font-size: 14px;">
        Este enlace expira en 1 hora. Si no solicitaste este cambio, podés ignorar este email.
      </p>
      <hr />
      <p style="color: #888; font-size: 12px;">
        Recibiste este correo porque se solicitó un restablecimiento de contraseña para tu cuenta.
      </p>
    </div>
    """
  end

  defp email_text(reset_url) do
    """
    Restablecer contraseña

    Recibimos una solicitud para restablecer tu contraseña en Colloq.

    Abrí el siguiente enlace para crear una nueva contraseña:
    #{reset_url}

    Este enlace expira en 1 hora. Si no solicitaste este cambio, podés ignorar este email.
    """
  end
end
