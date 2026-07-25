import Config

# Test-specific: tiny shell. Database is managed by Ecto.Adapters.SQL.Sandbox.
# Mix test suffixes DB name with MIX_TEST_PARTITION for parallel runs.

# runtime.exs deliberately skips the repo in :test unless DATABASE_URL is set,
# so the connection details have to live here or `mix test` dies in ecto.create
# with "key :database not found".
config :colloq, Colloq.Repo,
  username: System.get_env("TEST_DB_USER", "colloq"),
  password: System.get_env("TEST_DB_PASS", "colloq"),
  hostname: System.get_env("TEST_DB_HOST", "localhost"),
  database: "colloq_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

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
