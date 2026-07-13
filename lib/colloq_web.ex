defmodule ColloqWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.
  """

  def static_paths do
    ~w(assets fonts images favicon.ico favicon.svg robots.txt manifest.json sw.js icons emojis uploads)
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ColloqWeb.Layouts]

      import Plug.Conn
      import ColloqWeb.Gettext

      unquote(verified_routes())

      alias ColloqWeb.Router.Helpers, as: Routes
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {ColloqWeb.Layouts, :app}

      on_mount {ColloqWeb.UserAuth, :default}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.HTML.Form
      use PhoenixHTMLHelpers

      import ColloqWeb.CoreComponents
      import ColloqWeb.Components.Lucide, only: [icon: 1]
      import ColloqWeb.Gettext

      unquote(verified_routes())

      alias Phoenix.LiveView.JS

      defp es_locale(datetime) do
        # Spanish relative time using basic distance-of-time
        seconds = DateTime.diff(DateTime.utc_now(), datetime) |> abs()

        cond do
          seconds < 60 -> "ahora"
          seconds < 3600 -> "#{div(seconds, 60)}m"
          seconds < 86_400 -> "#{div(seconds, 3600)}h"
          seconds < 2_592_000 -> "#{div(seconds, 86_400)}d"
          true -> Calendar.strftime(datetime, "%d/%m/%Y")
        end
      end
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      import ColloqWeb.Gettext
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ColloqWeb.Endpoint,
        router: ColloqWeb.Router,
        statics: ColloqWeb.static_paths()
    end
  end

  def json do
    quote do
      alias ColloqWeb.Router.Helpers, as: Routes
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
