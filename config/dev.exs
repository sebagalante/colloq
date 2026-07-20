import Config

# Development-specific: tiny shell, everything else from runtime.exs
#
# Load .env file for dev convenience (never committed).
# Parsed inline rather than via the dotenv dep, whose module isn't on the code
# path this early during config evaluation.
with env_path <- Path.expand("../.env", __DIR__),
     true <- File.exists?(env_path),
     {:ok, contents} <- File.read(env_path) do
  contents
  |> String.split("\n")
  |> Enum.each(fn line ->
    line = String.trim(line)

    unless line == "" or String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] -> System.put_env(String.trim(key), String.trim(value))
        _ -> :ok
      end
    end
  end)
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
