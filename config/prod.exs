import Config

# Production compile-time hints ONLY.
# ALL secrets and runtime values come from runtime.exs + Infisical Cloud.

# Cache static manifest for faster asset serving
config :colloq, ColloqWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Enable dev_routes? No — only in dev/test
config :colloq, :dev_routes, false
