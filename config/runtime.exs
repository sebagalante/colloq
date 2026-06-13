import Config

# ============================================================================
# RUNTIME CONFIGURATION — all values read from env vars / Infisical on boot
# This is the main config file for the application.
# ============================================================================

# --- Core secrets (strict in prod, lenient in dev) ---
secret_key_base = System.get_env("SECRET_KEY_BASE", System.get_env("DEV_SECRET_KEY_BASE", "dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev"))

# --- Database ---
database_url = System.get_env("DATABASE_URL") ||
  case config_env() do
    :dev -> "ecto://colloq:colloq@localhost/colloq_dev"
    :test -> "ecto://colloq:colloq@localhost/colloq_test#{System.get_env("MIX_TEST_PARTITION")}"
    :prod -> nil
  end

# --- Host ---
phx_host = System.get_env("PHX_HOST", "localhost")
port = String.to_integer(System.get_env("PORT", "4000"))

# --- Application ---
config :colloq,
  # Media storage: swappable per env
  media_storage:
    case config_env() do
      :prod -> System.get_env("MEDIA_STORAGE", "bunny") |> String.to_existing_atom() |> (&(Module.concat(Colloq.Media, &1))).()
      :dev -> System.get_env("MEDIA_STORAGE", "imgbb") |> String.to_existing_atom() |> (&(Module.concat(Colloq.Media, &1))).()
      :test -> Colloq.Media.Local
    end

# --- Repo ---
if config_env() != :test or System.get_env("DATABASE_URL") do
  config :colloq, Colloq.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end

# --- Endpoint ---
config :colloq, ColloqWeb.Endpoint,
  url: [host: phx_host, port: 443, scheme: "https"],
  http: [
    ip: {0, 0, 0, 0, 0, 0, 0, 0},
    port: port
  ],
  secret_key_base: secret_key_base

# Only SSL in prod with valid cert (Caddy handles TLS termination otherwise)
if config_env() == :prod and System.get_env("FORCE_SSL", "false") == "true" do
  config :colloq, ColloqWeb.Endpoint,
    force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]
end

# --- External API keys (read from env — Infisical injects these) ---
# Football data
config :colloq, :api_football_key, System.get_env("API_FOOTBALL_KEY")
config :colloq, :football_data_api_key, System.get_env("FOOTBALL_DATA_API_KEY")

# LLM providers
config :colloq, :groq_api_key, System.get_env("GROQ_API_KEY")
config :colloq, :nvidia_nim_api_key, System.get_env("NVIDIA_NIM_API_KEY")
config :colloq, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
config :colloq, :openrouter_api_key, System.get_env("OPENROUTER_API_KEY")

# Storage & upload
config :colloq, :imgbb_api_key, System.get_env("IMGBB_API_KEY")
config :colloq, :bunny_api_key, System.get_env("BUNNY_API_KEY")
config :colloq, :bunny_storage_zone, System.get_env("BUNNY_STORAGE_ZONE")

# OAuth
config :colloq, :google_client_id, System.get_env("GOOGLE_CLIENT_ID")
config :colloq, :google_client_secret, System.get_env("GOOGLE_CLIENT_SECRET")

# Web Push (PWA)
config :colloq, :vapid_public_key, System.get_env("VAPID_PUBLIC_KEY")
config :colloq, :vapid_private_key, System.get_env("VAPID_PRIVATE_KEY")

# Admin network restriction
config :colloq, :admin_allowed_cidrs,
  System.get_env("ADMIN_ALLOWED_CIDRS", "")
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

# Email
config :colloq, Colloq.Mailer,
  adapter:
    case config_env() do
      :prod -> Swoosh.Adapters.SMTP
      _ -> Swoosh.Adapters.Local
    end

# Swoosh SMTP config (prod only, from env)
if config_env() == :prod do
  config :colloq, Colloq.Mailer,
    relay: System.get_env("SMTP_HOST"),
    port: String.to_integer(System.get_env("SMTP_PORT", "587")),
    username: System.get_env("SMTP_USER"),
    password: System.get_env("SMTP_PASS"),
    tls: :if_available,
    auth: :always
end

# Logger level
config :logger, :console,
  level:
    case config_env() do
      :dev -> :debug
      :test -> :warning
      :prod -> :info
    end
