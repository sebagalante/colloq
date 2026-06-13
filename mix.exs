defmodule Colloq.MixProject do
  use Mix.Project

  def project do
    [
      app: :colloq,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: [
        colloq: [
          include_executables_for: [:unix],
          applications: [colloq: :permanent],
          cookie: System.get_env("RELEASE_COOKIE"),
          strip_beams: true
        ]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Colloq.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  defp deps do
    [
      # Phoenix ecosystem
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # Data layer
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},

      # Auth
      {:bcrypt_elixir, "~> 3.1"},
      {:guardian, "~> 2.3"},

      # Background jobs
      {:oban, "~> 2.18"},

      # Caching
      {:cachex, "~> 3.6"},

      # HTTP client (chosen over Tesla — see Recap v9)
      {:req, "~> 0.5"},

      # Web Push (PWA)
      {:web_push_encryption, "~> 0.3"},

      # JSON
      {:jason, "~> 1.4"},

      # HTML sanitization for user/bot post bodies rendered as raw HTML
      {:html_sanitize_ex, "~> 1.4"},

      # Telemetry
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # Internationalization
      {:gettext, "~> 0.26"},

      # Env loading (dev only)
      {:dotenv, "~> 3.0", only: [:dev, :test]},

      # Testing
      {:mox, "~> 1.2", only: :test},
      {:ex_machina, "~> 2.8", only: :test},
      {:faker, "~> 0.18", only: :test},

      # Observability
      {:plug_cowboy, "~> 2.7"},
      {:swoosh, "~> 1.16"},
      {:hackney, "~> 1.20"},
      {:gen_smtp, "~> 1.3"},  # Swoosh SMTP adapter

      # Utilities
      {:sweet_xml, "~> 0.7"},     # Nitter RSS parsing
      {:nimble_parsec, "~> 1.4"}  # Custom parsers if needed
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind colloq", "esbuild colloq"],
      "assets.deploy": ["tailwind colloq --minify", "esbuild colloq --minify", "phx.digest"]
    ]
  end
end
