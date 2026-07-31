defmodule ColloqWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :colloq

  # The session will be stored in a secure cookie.
  #
  # `signing_salt` is deliberately NOT in this list: a module attribute is
  # evaluated at compile time, so reading the env var here would bake the build
  # machine's value into the release and silently ignore whatever prod exports.
  # It's fetched per request in session_options/0 instead.
  @session_options [
    store: :cookie,
    key: "_colloq_session",
    # Secure and SameSite are set per environment in runtime.exs
    same_site: "Lax"
  ]

  @doc """
  Session options with the runtime signing salt applied.

  Called on every request (via the `session` plug below) and by the LiveView
  socket's `connect_info`, which takes an MFA precisely so the value is read at
  runtime rather than captured at compile time.
  """
  def session_options do
    salt = Application.fetch_env!(:colloq, __MODULE__)[:session_signing_salt]
    Keyword.put(@session_options, :signing_salt, salt)
  end

  # Socket mount for LiveView.
  # Longpoll is enabled so the client's `longPollFallbackMs` fallback works when
  # the WebSocket can't connect (e.g. proxies / WSL2) — otherwise LiveView never
  # connects and the page renders but is completely non-interactive.
  # `peer_data` + `x_headers` let a LiveView work out the client's address: the
  # RemoteIp plug below only runs for plain HTTP requests, so inside a connected
  # LiveView `peer_data` alone is Caddy on loopback. Registration needs the real
  # address (see ColloqWeb.UserLive.Registration), which means walking the same
  # forwarded chain the plug does.
  @connect_info [:peer_data, :x_headers, session: {__MODULE__, :session_options, []}]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: @connect_info],
    longpoll: [connect_info: @connect_info]

  # Socket mount for channels (DMs, notifications, forum)
  socket "/socket", ColloqWeb.UserSocket,
    websocket: true

  # Sandbox CSP + nosniff for /uploads. Must stay above Plug.Static: static
  # responses never reach the router, so the browser pipeline's CSP misses them.
  plug ColloqWeb.Plugs.UploadHeaders

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

  # Caddy terminates TLS in front of us, so conn.remote_ip is the proxy's
  # address (127.0.0.1) unless the forwarded headers are honoured — every
  # login would otherwise be recorded as coming from localhost.
  #
  # SECURITY: `:proxies` lists hops to skip while walking the header chain; it
  # does NOT restrict who may send X-Forwarded-For. Verified: a request from a
  # public peer with a forged header still rewrites remote_ip. That is how
  # RemoteIp works — it assumes the app is only reachable through the proxy.
  # So this is safe exactly as long as the HTTP port isn't exposed directly:
  # bind it to loopback (or firewall it) and let Caddy be the only ingress.
  # Otherwise anyone can pick the IP we record for moderation.
  plug RemoteIp,
    headers: ~w(x-forwarded-for),
    proxies: {__MODULE__, :trusted_proxies, []}

  @doc """
  Proxy hops to skip when reading the forwarded chain: loopback (Caddy on the
  same host) plus anything in TRUSTED_PROXIES, comma-separated.
  """
  def trusted_proxies do
    configured =
      :colloq
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:trusted_proxies, [])

    ~w(127.0.0.0/8 ::1/128) ++ configured
  end

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  # `plug Plug.Session, opts` would freeze the salt at compile time; this
  # inits per request so the runtime value wins.
  plug :session
  plug ColloqWeb.Router

  defp session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end
end
