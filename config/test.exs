import Config

# Test-specific: tiny shell. Database is managed by Ecto.Adapters.SQL.Sandbox.
# Mix test suffixes DB name with MIX_TEST_PARTITION for parallel runs.

config :colloq, Colloq.Repo,
  pool: Ecto.Adapters.SQL.Sandbox

config :colloq, ColloqWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test-test",
  server: false

config :logger, level: :warning

# Initialize plugs at runtime for test speed
config :phoenix, :plug_init_mode, :runtime

# Disable swoosh in tests
config :swoosh, :api_client, false

# Oban: testing mode (inline or manual)
config :colloq, Oban, testing: :inline
