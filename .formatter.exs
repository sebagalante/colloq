# Used by "mix format" for consistent formatting.
# Import deps' config so their formatter rules are picked up.
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_live_view],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"],
  subdirectories: ["priv/*/migrations"]
]
