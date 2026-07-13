import Config

# General application configuration — compile-time only.
# Runtime config lives in runtime.exs. Secrets NEVER go here.

config :colloq,
  ecto_repos: [Colloq.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  # Media storage adapter: swap per env
  media_storage: Colloq.Media.Local,
  # Compile-time flag (router builds the voice-rooms scope from this); the value
  # must match runtime.exs to satisfy Application.compile_env validation.
  voice_rooms_enabled: false

# Phoenix endpoint
config :phoenix, :json_library, Jason

config :colloq, ColloqWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: ColloqWeb.ErrorHTML, json: ColloqWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Colloq.PubSub,
  live_view: [signing_salt: System.get_env("PHX_LIVE_SIGNING_SALT", "todo-change-me")]

# Ueberauth OAuth providers
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]},
    microsoft: {Ueberauth.Strategy.Microsoft, [default_scope: "openid email profile"]},
    facebook: {Ueberauth.Strategy.Facebook, [default_scope: "email"]},
    twitter: {Ueberauth.Strategy.Twitter, []},
    discord: {Ueberauth.Strategy.Discord, [default_scope: "identify email"]}
  ]

# Oban job queues
config :colloq, Oban,
  repo: Colloq.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},  # 7 days
    {Oban.Plugins.Cron,
     crontab: [
       {"0 9 * * *", Colloq.Workers.DigestWorker},
       {"0 9 * * *", Colloq.Workers.ScoreBotWorker, args: %{action: "preview"}},
       {"0 2 * * *", Colloq.Workers.TrustPromotionWorker}
     ]}
  ],
  queues: [
    default: 10,
    notifications: 20,
    events: 10,
    mailers: 5,
    media: 5,
    llm: 5,
    scorebot: 5
  ]

# Mailer
config :colloq, Colloq.Mailer, adapter: Swoosh.Adapters.Local

# Internationalization
config :colloq, ColloqWeb.Gettext, default_locale: "es", locales: ~w(es en)

# Swoosh API client
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Logger
config :logger, :console, format: "$time [$level] $message\n", level: :info

# Asset pipeline
config :colloq, :css_destination, Path.join(__DIR__, "../priv/static/assets/app.css")
config :colloq, :js_destination, Path.join(__DIR__, "../priv/static/assets/app.js")

# esbuild — bundles assets/js/app.js → priv/static/assets/app.js
# Phoenix deps (phoenix, phoenix_html, phoenix_live_view) resolve from
# the deps/ dir via NODE_PATH; npm packages (tiptap) resolve from
# assets/node_modules after `npm install` in assets/.
config :esbuild,
  version: "0.17.11",
  colloq: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# tailwind — compiles assets/css/app.css → priv/static/assets/app.css
# Looks for tailwind.config.js in the cd directory (assets/).
config :tailwind,
  version: "3.4.0",
  colloq: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Import environment-specific config (these are tiny shells)
import_config "#{config_env()}.exs"
