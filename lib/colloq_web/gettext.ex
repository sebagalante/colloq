defmodule ColloqWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.
  
  Default locale is Spanish (es) for the Racing Club community.
  """
  use Gettext, otp_app: :colloq

  def default_locale, do: "es"
  def available_locales, do: ~w(es en)
end
