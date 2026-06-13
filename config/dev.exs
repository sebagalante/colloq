import Config

# Development-specific: tiny shell, everything else from runtime.exs
#
# Load .env file for dev convenience (never committed)
if File.exists?(Path.expand("../.env", __DIR__)) do
  Dotenv.load!()
end

# Enable dev-only features
config :colloq, :dev_routes, true

config :colloq, ColloqWeb.Endpoint,
  # Code reloading
  code_reloader: true,
  debug_errors: true,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:colloq, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:colloq, ~w(--watch)]}
  ]

config :logger, :console, format: "[$level] $message\n", level: :debug

# Initialize plugs at runtime for faster development
config :phoenix, :plug_init_mode, :runtime

# Disable swoosh cache in dev
config :swoosh, :api_client, false
