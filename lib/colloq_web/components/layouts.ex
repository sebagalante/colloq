defmodule ColloqWeb.Layouts do
  @moduledoc """
  Root and app layouts for Colloq.
  """
  use ColloqWeb, :html

  import ColloqWeb.Components.Navigation

  embed_templates "layouts/*"

  @doc """
  Site branding for the current render.

  Normally assigned by `ColloqWeb.UserAuth.fetch_current_user/2`; falls back to
  a fresh (cached) lookup so a layout rendered outside that pipeline — error
  pages, mailers — still gets the site's name rather than crashing on a missing
  assign.
  """
  def branding(assigns) do
    case assigns[:branding] do
      nil -> Colloq.SiteSettings.branding()
      branding -> branding
    end
  end

  @doc """
  Returns the PWA theme-color meta tag value for a given theme.
  """
  def theme_color("racing_light"), do: "#AFD4EF"
  def theme_color("racing_celeste"), do: "#7FB3DB"
  def theme_color("racing_navy"), do: "#06101F"
  def theme_color("racing"), do: "#06101F"
  def theme_color("light"), do: "#2563eb"
  def theme_color(_), do: "#1d4ed8"
end
