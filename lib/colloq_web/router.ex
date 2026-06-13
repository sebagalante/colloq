defmodule ColloqWeb.Router do
  use ColloqWeb, :router

  import ColloqWeb.UserAuth

  @moduledoc """
  Router for Colloq.
  
  Pipelines:
  - :browser → standard browser requests
  - :api → JSON API requests
  - :admin_network → IP-restricted admin routes
  
  Note: Bot detection is handled by heuristic checks in Moderation context,
  not by an external service.
  """

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ColloqWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self'; connect-src 'self' ws: wss:; media-src 'self' https:;"
    }
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :admin_network do
    plug ColloqWeb.Plugs.VpnOnly
    plug :require_authenticated_user
    plug :require_admin_user
  end

  # --- PUBLIC ROUTES ---
  scope "/", ColloqWeb do
    pipe_through :browser

    live "/", ForumLive.Index, :index
    live "/c/:slug", ForumLive.Index, :category
    live "/t/:id", ForumLive.Topic, :show
    live "/t/:id/:slug", ForumLive.Topic, :show

    get "/go", LinkController, :redirect

    # Guest can view but not post — auth checked at LiveView level
    live "/register", UserLive.Registration, :new
    live "/login", UserLive.Login, :new
    live "/forgot-password", UserLive.ForgotPassword, :new
    live "/reset-password", UserLive.ResetPassword, :edit

    # OAuth callbacks
    get "/auth/:provider/callback", AuthController, :callback
    get "/auth/failure", AuthController, :failure
  end

  # --- AUTHENTICATED ROUTES ---
  scope "/", ColloqWeb do
    pipe_through [:browser, :require_authenticated_user]

    live "/forum/new", ForumLive.Index, :new_topic
    live "/messages", UserLive.Messages, :index
    live "/messages/:id", UserLive.Messages, :show
    live "/u/:username", UserLive.Profile, :show
    live "/settings", UserLive.Settings, :edit

    live "/comparar", PlayerComparisonLive, :show
    live "/predicciones", PredictionsLive, :index
  end

  # --- API ---
  scope "/api/v1", ColloqWeb do
    pipe_through :api

    post "/push/subscribe", PushController, :subscribe
    delete "/push/subscribe", PushController, :unsubscribe
    post "/automations/:id/trigger", AutomationController, :trigger
  end

  # --- ADMIN (IP-restricted) ---
  scope "/admin", ColloqWeb do
    pipe_through [:browser, :admin_network]

    live "/", AdminLive.Dashboard, :index
    live "/automations", AdminLive.Automations, :index
    live "/automations/new", AdminLive.Automations, :new
    live "/automations/:id/edit", AdminLive.Automations, :edit
    live "/bots", AdminLive.Bots, :index
    live "/bots/new", AdminLive.Bots, :new
    live "/bots/:id/edit", AdminLive.Bots, :edit
    live "/settings/llm", AdminLive.LlmSettings, :edit
    live "/settings/x_feed", AdminLive.XFeedSettings, :edit
    live "/settings", AdminLive.Settings, :index
  end

  # Enable dev routes (LiveDashboard / Swoosh mailbox)
  if Application.compile_env(:colloq, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: ColloqWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
