defmodule ColloqWeb.Router do
  use ColloqWeb, :router

  import ColloqWeb.UserAuth

  @moduledoc """
  Router for Colloq.

  Pipelines:
  - :browser → standard browser requests
  - :api → JSON API requests
  - :admin_base → auth + admin role check

  2FA verification is enforced on admin routes for users with TOTP enabled.
  """

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ColloqWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://platform.twitter.com https://cdn.syndication.twimg.com; style-src 'self' 'unsafe-inline' https://platform.twitter.com https://fonts.googleapis.com; img-src 'self' data: https:; font-src 'self' https://fonts.gstatic.com; connect-src 'self' ws: wss: https://syndication.twitter.com https://cdn.syndication.twimg.com; media-src 'self' https:; frame-src 'self' https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com https://platform.twitter.com https://twitter.com https://x.com https://open.spotify.com https://w.soundcloud.com https://www.facebook.com https://web.facebook.com https://www.instagram.com;"
    }
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  # JSON API that still needs the browser session (current_user) — e.g. the
  # hover user-card popover, which shows a "Message" button for logged-in users.
  pipeline :browser_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_user
  end

  # Admin base pipeline — auth + role check, NO IP restriction
  pipeline :admin_base do
    plug :require_authenticated_user
    plug :require_admin_user
    plug :require_2fa_verified
  end

  pipeline :require_moderator do
    plug ColloqWeb.Plugs.RequirePermission, :view_users
  end

  pipeline :require_admin do
    plug ColloqWeb.Plugs.RequirePermission, :view_dashboard
  end

  pipeline :require_super_admin do
    plug ColloqWeb.Plugs.RequirePermission, :assign_roles
  end

  # --- PUBLIC ROUTES ---
  scope "/", ColloqWeb do
    pipe_through :browser

    live "/", ForumLive.Index, :index
    live "/c/:slug", ForumLive.Index, :category
    live "/tag/:slug", ForumLive.Index, :tag
    live "/t/:id", ForumLive.Topic, :show
    live "/t/:id/:slug", ForumLive.Topic, :show
    live "/u/:username", UserLive.Profile, :show

    live "/search", SearchLive, :index
    live "/members", MembersLive, :index
    live "/leaderboard", LeaderboardLive, :index
    live "/badges", BadgesLive, :index
    live "/about", StaticLive, :about
    live "/guidelines", StaticLive, :guidelines

    get "/go", LinkController, :redirect

    # Session management (for LiveView login)
    get "/session", SessionController, :create
    get "/session/2fa", SessionController, :create_with_2fa
    get "/session/2fa/complete", SessionController, :finalize_2fa
    get "/logout", SessionController, :delete
    get "/session/suspended", SessionController, :suspended

    # Guest can view but not post — auth checked at LiveView level
    live "/register", UserLive.Registration, :new
    live "/login", UserLive.Login, :new
    live "/2fa", UserLive.TwoFactor, :new
    live "/forgot-password", UserLive.ForgotPassword, :new
    live "/reset-password", UserLive.ResetPassword, :edit

    # OAuth (Ueberauth)
    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
    get "/auth/failure", AuthController, :failure
  end

  # --- AUTHENTICATED ROUTES ---
  scope "/", ColloqWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/api/upload", UploadController, :create
    post "/api/chat/upload", UploadController, :attachment
    get "/api/users/search", MentionController, :search
    get "/api/stickers", MentionController, :stickers
    get "/api/tags/search", MentionController, :tags

    live "/forum/new", ForumLive.Index, :new_topic
    live "/messages", UserLive.Messages, :index
    live "/messages/:id", UserLive.Messages, :show
    live "/notifications", UserLive.Notifications, :index
    live "/settings", UserLive.Settings, :edit
    live "/bookmarks", UserLive.Bookmarks, :index

    live "/comparar", PlayerComparisonLive, :show
    live "/jugador", PlayerCardLive, :index
    live "/predicciones", PredictionsLive, :index
  end

  # --- USER CARD (JSON, session-aware) ---
  scope "/", ColloqWeb do
    pipe_through :browser_api

    get "/u/:username/card", UserCardController, :show

    # Public: profiles and topics are readable logged-out, and their text can
    # contain :shortcodes:. Behind auth the map never loaded for anonymous
    # readers, so shortcodes stayed as raw text for them. The list is just
    # names and image paths — nothing to protect.
    get "/api/emojis", MentionController, :emojis
  end

  # --- API ---
  scope "/api/v1", ColloqWeb do
    pipe_through :api

    post "/push/subscribe", PushController, :subscribe
    delete "/push/subscribe", PushController, :unsubscribe
    post "/automations/:id/trigger", AutomationController, :trigger
  end

  # --- ADMIN: Moderator+ (moderator, admin, super_admin) ---
  # No IP restriction — accessible from any network
  scope "/admin", ColloqWeb do
    pipe_through [:browser, :admin_base, :require_moderator]

    live "/moderation", AdminLive.Moderation, :index
    live "/users", AdminLive.Users, :index
    live "/categories", AdminLive.Categories, :index
    live "/categories/new", AdminLive.Categories, :new
    live "/categories/:id/edit", AdminLive.Categories, :edit
    live "/tags", AdminLive.Tags, :index
    live "/tags/new", AdminLive.Tags, :new
    live "/tags/:id/edit", AdminLive.Tags, :edit
  end

  # --- ADMIN: Admin+ (admin, super_admin) ---
  # No IP restriction — accessible from any network
  scope "/admin", ColloqWeb do
    pipe_through [:browser, :admin_base, :require_admin]

    live "/", AdminLive.Dashboard, :index
    live "/automations", AdminLive.Automations, :index
    live "/automations/new", AdminLive.Automations, :new
    live "/automations/:id/edit", AdminLive.Automations, :edit
    live "/bots", AdminLive.Bots, :index
    live "/bots/new", AdminLive.Bots, :new
    live "/bots/:id/edit", AdminLive.Bots, :edit
    live "/badges", AdminLive.Badges, :index
    live "/badges/new", AdminLive.Badges, :new
    live "/badges/:id/edit", AdminLive.Badges, :edit
    live "/emojis", AdminLive.Emojis, :index
    live "/stickers", AdminLive.Stickers, :index
    live "/sofascore", AdminLive.Sofascore, :index
    live "/settings/llm", AdminLive.LlmSettings, :edit
    live "/settings/x_feed", AdminLive.XFeedSettings, :edit
  end

  # --- ADMIN: Super Admin only (super_admin) ---
  # Gated by super-admin role + 2FA (no network/IP restriction).
  scope "/admin", ColloqWeb do
    pipe_through [:browser, :admin_base, :require_super_admin]

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

  # Voice rooms (experimental, behind feature flag)
  if Application.compile_env(:colloq, :voice_rooms_enabled, false) do
    scope "/", ColloqWeb do
      pipe_through :browser

      live "/voice/:slug", VoiceRoomLive, :show
    end
  end
end
