defmodule ColloqWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :colloq

  # The session will be stored in a secure cookie.
  @session_options [
    store: :cookie,
    key: "_colloq_session",
    signing_salt: System.get_env("PHX_SESSION_SIGNING_SALT", "colloq2024"),
    # Secure and SameSite are set per environment in runtime.exs
    same_site: "Lax"
  ]

  # Socket mount for LiveView.
  # Longpoll is enabled so the client's `longPollFallbackMs` fallback works when
  # the WebSocket can't connect (e.g. proxies / WSL2) — otherwise LiveView never
  # connects and the page renders but is completely non-interactive.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Socket mount for channels (DMs, notifications, forum)
  socket "/socket", ColloqWeb.UserSocket,
    websocket: true

  # Serve static assets at / from priv/static
  plug Plug.Static,
    at: "/",
    from: :colloq,
    gzip: Mix.env() == :prod,
    only: ColloqWeb.static_paths()

  # Code reloading for dev
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :colloq
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ColloqWeb.Router
end
