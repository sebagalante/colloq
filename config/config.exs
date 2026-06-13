import Config

# General application configuration — compile-time only.
# Runtime config lives in runtime.exs. Secrets NEVER go here.

config :colloq,
  ecto_repos: [Colloq.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  # Media storage adapter: swap per env
  media_storage: Colloq.Media.Local

# Phoenix endpoint
config :colloq, ColloqWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Plug.Cowboy,
  render_errors: [
    formats: [html: ColloqWeb.ErrorHTML, json: ColloqWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Colloq.PubSub,
  live_view: [signing_salt: System.get_env("PHX_LIVE_SIGNING_SALT", "todo-change-me")]

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

# PubSub
config :colloq, Colloq.PubSub, adapter: Phoenix.PubSub.PG2

# Asset pipeline
config :colloq, :css_destination, Path.join(__DIR__, "../priv/static/assets/app.css")
config :colloq, :js_destination, Path.join(__DIR__, "../priv/static/assets/app.js")

# Import environment-specific config (these are tiny shells)
import_config "#{config_env()}.exs"
