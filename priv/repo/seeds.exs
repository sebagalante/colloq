# Colloq database seeds
# Run with: mix run priv/repo/seeds.exs

alias Colloq.Repo
alias Colloq.Accounts.User
alias Colloq.Forum.Category
alias Colloq.SiteSettings.Setting

IO.puts("🌱 Seeding Colloq database...")

# =============================================================================
# Categories
# =============================================================================
categories = [
  %{
    name: "Racing Club",
    slug: "racing",
    description: "Todo sobre La Academia: partidos, jugadores, actualidad del club.",
    color: "#0038A8",
    icon: "⚽",
    position: 1
  },
  %{
    name: "Fútbol Argentino",
    slug: "futbol-argentino",
    description: "Liga Profesional, Copa Argentina, selección, fútbol de ascenso.",
    color: "#22c55e",
    icon: "🇦🇷",
    position: 2
  },
  %{
    name: "Fútbol Internacional",
    slug: "futbol-internacional",
    description: "Copas, ligas europeas, Mercado de Pases, selecciones.",
    color: "#a855f7",
    icon: "🌍",
    position: 3
  },
  %{
    name: "Off-Topic",
    slug: "off-topic",
    description: "Cualquier otra cosa: música, gaming, series, vida.",
    color: "#6b7280",
    icon: "💬",
    position: 4
  },
  %{
    name: "Sugerencias",
    slug: "sugerencias",
    description: "Reportar bugs, sugerir mejoras, feedback del foro.",
    color: "#f59e0b",
    icon: "💡",
    position: 5
  }
]

Enum.each(categories, fn attrs ->
  case Category.changeset(%Category{}, attrs) |> Repo.insert() do
    {:ok, cat} -> IO.puts("  ✓ Category: #{cat.name}")
    {:error, _} -> IO.puts("  ⚠ Category exists: #{attrs.name}")
  end
end)

# =============================================================================
# Site Settings (defaults)
# =============================================================================
default_settings = [
  %{key: "site_title", value: "Colloq", type: "string", group: "general",
    description: "Título del sitio mostrado en el header", public: true},
  %{key: "site_description", value: "Comunidad de Racing Club de Avellaneda",
    type: "string", group: "general", public: true},
  %{key: "registration_mode", value: "open", type: "string", group: "security",
    description: "Modo de registro: open, invite, closed"},
  %{key: "max_post_length", value: "50000", type: "integer", group: "forum",
    description: "Longitud máxima de posts"},
  %{key: "min_post_length", value: "10", type: "integer", group: "forum",
    description: "Longitud mínima de posts"},
  %{key: "auto_close_threshold", value: "50000", type: "integer", group: "forum",
    description: "Cantidad de posts antes de cerrar automáticamente un hilo"},
  %{key: "archive_after_days", value: "90", type: "integer", group: "forum",
    description: "Días tras los cuales un hilo se archiva automáticamente"},
  %{key: "x_feed_nitter_url",
    value: "https://nitter.net", type: "string", group: "integrations",
    description: "URL base de la instancia Nitter para feeds de X/Twitter"},
  %{key: "x_feed_accounts",
    value: ~s(["RacingClub", "RacingRadio", "SoloRacingOK"]), type: "json", group: "integrations",
    description: "Cuentas de X a monitorear (JSON array)"},
  %{key: "x_feed_keywords",
    value: ~s(["Racing", "Academia", "Maravilla"]), type: "json", group: "integrations",
    description: "Palabras clave para filtrar tweets"},
  %{key: "radio_stations",
    value: ~s([
      {"name": "La Red AM 910", "url": "https://stream.lt8.com.ar"},
      {"name": "Rivadavia AM 630", "url": "https://stream.rivadavia.com.ar"},
      {"name": "Continental AM 590", "url": "https://stream.continental.com.ar"}
    ]), type: "json", group: "match_day",
    description: "Emisoras de radio para el reproductor del match day"}
]

Enum.each(default_settings, fn attrs ->
  case Repo.get_by(Setting, key: attrs.key) do
    nil ->
      %Setting{}
      |> Setting.changeset(attrs)
      |> Repo.insert!()
      IO.puts("  ✓ Setting: #{attrs.key}")

    existing ->
      :ok
  end
end)

# =============================================================================
# Bot personas (system bots)
# =============================================================================
# ScoreBot will be seeded when migration 025 (bot_personas) is applied.
# In the meantime, the bot_system table holds basic system bot config.

bot_system_entries = [
  %{name: "ScoreBot", slug: "scorebot", type: "persona", active: true,
    config: %{managed_by_worker: "ScoreBotWorker", description: "Match day events"}},
  %{name: "WelcomeBot", slug: "welcomebot", type: "persona", active: true,
    config: %{managed_by_worker: "WelcomeBotWorker", description: "Welcome DMs"}},
  %{name: "DigestBot", slug: "digestbot", type: "persona", active: true,
    config: %{managed_by_worker: "DigestWorker", description: "Daily digest"}},
  %{name: "SpamDetector", slug: "spam-detector", type: "system", active: true,
    config: %{heuristics_first: true, llm_fallback_provider: "groq"}},
  %{name: "TrustPromoter", slug: "trust-promoter", type: "system", active: true,
    config: %{cron: "2:00 AM daily"}},
]

Enum.each(bot_system_entries, fn attrs ->
  now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  data = Map.merge(attrs, %{
    api_key: nil,
    inserted_at: now,
    updated_at: now
  })

  case Repo.get_by(Colloq.Bots.BotSystem, slug: attrs.slug) do
    nil ->
      Repo.insert_all(Colloq.Bots.BotSystem, [data])
      IO.puts("  ✓ Bot: #{attrs.name}")
    _ ->
      :ok
  end
end)

# =============================================================================
# Trust Levels
# =============================================================================
trust_levels = [
  %{level: 0, name: "Nuevo", min_posts: 0, min_days_registered: 0,
    can_create_topics: false, can_send_pms: false, can_edit_posts: false,
    can_upload_images: false, daily_post_limit: 10, daily_reaction_limit: 20},
  %{level: 1, name: "Básico", min_posts: 5, min_days_registered: 1,
    can_create_topics: true, can_send_pms: true, can_edit_posts: false,
    can_upload_images: false, daily_post_limit: 20, daily_reaction_limit: 50},
  %{level: 2, name: "Miembro", min_posts: 15, min_days_registered: 3,
    can_create_topics: true, can_send_pms: true, can_edit_posts: true,
    can_upload_images: true, daily_post_limit: 0, daily_reaction_limit: 0},
  %{level: 3, name: "Regular", min_posts: 30, min_days_registered: 7,
    can_create_topics: true, can_send_pms: true, can_edit_posts: true,
    can_upload_images: true, daily_post_limit: 0, daily_reaction_limit: 0},
  %{level: 4, name: "Líder", min_posts: 0, min_days_registered: 0,
    can_create_topics: true, can_send_pms: true, can_edit_posts: true,
    can_upload_images: true, daily_post_limit: 0, daily_reaction_limit: 0}
]

Enum.each(trust_levels, fn attrs ->
  case Repo.get_by(Colloq.Trust.TrustLevel, level: attrs.level) do
    nil ->
      Repo.insert_all(Colloq.Trust.TrustLevel, [Map.merge(attrs, %{
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      })])
      IO.puts("  ✓ Trust Level: #{attrs.name} (TL#{attrs.level})")
    _ ->
      :ok
  end
end)

# =============================================================================
# Admin user (if no users exist)
# =============================================================================
if Repo.aggregate(User, :count, :id) == 0 do
  admin = %User{}
    |> User.registration_changeset(%{
      email: "admin@colloq.local",
      username: "admin",
      display_name: "Administrador",
      password: "adminchangeit",
      password_confirmation: "adminchangeit"
    })
    |> Ecto.Changeset.change(
      is_admin: true,
      trust_level: 4,
      oauth_provider: "local"
    )
    |> Repo.insert!()

  IO.puts("  ✓ Admin user: #{admin.email} / adminchangeit")
end

IO.puts("✅ Seeding complete.")