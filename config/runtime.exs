import Config

# ============================================================================
# RUNTIME CONFIGURATION — all values read from env vars / Infisical on boot
# This is the main config file for the application.
# ============================================================================

# --- Core secrets (strict in prod, lenient in dev) ---
secret_key_base = System.get_env("SECRET_KEY_BASE", System.get_env("DEV_SECRET_KEY_BASE", "dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev-dev"))

# --- Database ---
# Treat an empty DATABASE_URL the same as unset (empty strings are truthy in Elixir).
database_url =
  case System.get_env("DATABASE_URL") do
    url when is_binary(url) and url != "" ->
      url

    _ ->
      case config_env() do
        :dev -> "ecto://colloq:colloq@localhost/colloq_dev"
        :test -> "ecto://colloq:colloq@localhost/colloq_test#{System.get_env("MIX_TEST_PARTITION")}"
        :prod -> nil
      end
  end

# --- Host ---
phx_host = System.get_env("PHX_HOST", "localhost")
port = String.to_integer(System.get_env("PORT", "4000"))

# --- Application ---
# Media storage: swappable per env
media_storage =
  case config_env() do
    :prod ->
      case System.get_env("MEDIA_STORAGE", "bunny") do
        "local" -> Colloq.Media.Local
        "imgbb" -> Colloq.Media.Imgbb
        "bunny" -> Colloq.Media.Bunny
        _ -> Colloq.Media.Bunny
      end
    :dev ->
      case System.get_env("MEDIA_STORAGE", "imgbb") do
        "local" -> Colloq.Media.Local
        "imgbb" -> Colloq.Media.Imgbb
        "bunny" -> Colloq.Media.Bunny
        _ -> Colloq.Media.Imgbb
      end
    :test -> Colloq.Media.Local
  end

config :colloq, media_storage: media_storage

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
config :colloq, :api_football_url, System.get_env("API_FOOTBALL_URL", "https://v3.football.api-sports.io")

# Sofascore
config :colloq, :sofascore_api_url, System.get_env("SOFASCORE_API_URL", "https://www.sofascore.com/api/v1")

# LLM providers
# Spam-classifier sidecar base URL. Overridable at runtime via the `spam_ml_url`
# site setting (which takes precedence); this env var is the deploy-time default.
config :colloq, :spam_ml_url, System.get_env("SPAM_ML_URL")

config :colloq, :groq_api_key, System.get_env("GROQ_API_KEY")

# Google Gemma via the Gemini API (OpenAI-compatible endpoint). GEMMA_API_KEY is
# a Google AI Studio API key.
config :colloq, :gemma_api_key, System.get_env("GEMMA_API_KEY")

config :colloq,
       :gemma_api_url,
       System.get_env("GEMMA_API_URL", "https://generativelanguage.googleapis.com/v1beta/openai")
config :colloq, :groq_api_url, System.get_env("GROQ_API_URL", "https://api.groq.com/openai/v1")
config :colloq, :nvidia_nim_api_key, System.get_env("NVIDIA_NIM_API_KEY")
config :colloq, :nvidia_api_url, System.get_env("NVIDIA_API_URL", "https://integrate.api.nvidia.com/v1")
config :colloq, :deepseek_api_key, System.get_env("DEEPSEEK_API_KEY")
config :colloq, :deepseek_api_url, System.get_env("DEEPSEEK_API_URL", "https://api.deepseek.com")
config :colloq, :openrouter_api_key, System.get_env("OPENROUTER_API_KEY")
config :colloq, :openrouter_api_url, System.get_env("OPENROUTER_API_URL", "https://openrouter.ai/api/v1")

# Nitter (X/Twitter RSS proxy)
config :colloq, :nitter_url, System.get_env("NITTER_URL", "https://nitter.net")

# Storage & upload
config :colloq, :imgbb_api_key, System.get_env("IMGBB_API_KEY")
config :colloq, :bunny_api_key, System.get_env("BUNNY_API_KEY")
config :colloq, :bunny_storage_zone, System.get_env("BUNNY_STORAGE_ZONE")
config :colloq, :bunny_storage_url, System.get_env("BUNNY_STORAGE_URL", "https://storage.bunnycdn.com")

# Base URL (for password reset links, etc.)
config :colloq, :base_url, System.get_env("BASE_URL", "https://colloq.ar")

# OAuth — Ueberauth provider credentials
# Google
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

# Microsoft
config :ueberauth, Ueberauth.Strategy.Microsoft.OAuth,
  client_id: System.get_env("MICROSOFT_CLIENT_ID"),
  client_secret: System.get_env("MICROSOFT_CLIENT_SECRET")

# Facebook
config :ueberauth, Ueberauth.Strategy.Facebook.OAuth,
  client_id: System.get_env("FACEBOOK_CLIENT_ID"),
  client_secret: System.get_env("FACEBOOK_CLIENT_SECRET")

# X (Twitter)
config :ueberauth, Ueberauth.Strategy.Twitter.OAuth,
  consumer_key: System.get_env("TWITTER_CONSUMER_KEY"),
  consumer_secret: System.get_env("TWITTER_CONSUMER_SECRET")

# Discord
config :ueberauth, Ueberauth.Strategy.Discord.OAuth,
  client_id: System.get_env("DISCORD_CLIENT_ID"),
  client_secret: System.get_env("DISCORD_CLIENT_SECRET")

# Web Push (PWA)
config :colloq, :vapid_public_key, System.get_env("VAPID_PUBLIC_KEY")
config :colloq, :vapid_private_key, System.get_env("VAPID_PRIVATE_KEY")

# WebRTC (Voice Rooms)
config :colloq, :voice_rooms_enabled, System.get_env("VOICE_ROOMS_ENABLED", "false") == "true"
config :colloq, :stun_url, System.get_env("STUN_URL", "stun:stun.l.google.com:19302")
config :colloq, :turn_url, System.get_env("TURN_URL")
config :colloq, :turn_username, System.get_env("TURN_USERNAME")
config :colloq, :turn_credential, System.get_env("TURN_CREDENTIAL")

# Email
mailer_adapter =
  case config_env() do
    :prod -> Swoosh.Adapters.SMTP
    _ -> Swoosh.Adapters.Local
  end

config :colloq, Colloq.Mailer, adapter: mailer_adapter

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
logger_level =
  case config_env() do
    :dev -> :debug
    :test -> :warning
    :prod -> :info
  end

config :logger, :console, level: logger_level
