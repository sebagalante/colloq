defmodule Colloq.Mailer do
  @moduledoc """
  Mailer module for Colloq.
  Adapter set per environment in runtime.exs (Swoosh.Adapters.Local in dev/test, SMTP in prod).
  """
  use Swoosh.Mailer, otp_app: :colloq
end