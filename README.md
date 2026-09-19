# Colloq

A Phoenix LiveView forum, built around football (Argentine football in
particular) but usable as a general-purpose discussion site. It bundles the
things a small community actually needs — real-time threads, DMs,
notifications, moderation, trust levels, badges — with a set of sports
features on top: live match threads fed by Sofascore, a score-prediction game
with automatic scoring and leaderboards, player cards and comparisons, and
bots that answer commands in-thread.

**Status: alpha / WIP.** See `plan.md` for the open issues list and
`plan-ui.md` for the design backlog.

---

## Stack

| Layer | Choice |
| --- | --- |
| Web | Phoenix 1.7 + LiveView 1.0, Tailwind, esbuild, TipTap editor |
| Data | PostgreSQL via [ParadeDB](https://paradedb.com) (BM25 full-text search), Ecto |
| Jobs | Oban |
| Cache | Cachex (`:forum_cache`, `:auth_cache`) |
| Auth | bcrypt + Guardian, TOTP 2FA, Ueberauth (Google, Microsoft, Facebook, Twitter, Discord) |
| Realtime | Phoenix PubSub, Channels, Presence |
| Media | Cloudflare R2 (S3-compatible) in prod, ImgBB in dev |
| Push | Web Push / VAPID (PWA) |
| i18n | Gettext — Spanish (default) and English |

The app is a single Elixir release. The only sidecar is an optional Python
spam classifier (`spam_classifier/`).

---

## Getting started

Requirements: Elixir ~> 1.18 with a matching OTP, Node.js (for the asset
toolchain), and Docker or Podman for the database.

```bash
cp .env.example .env        # fill in at minimum the three secrets below
docker compose up -d        # ParadeDB on localhost:5432
mix setup                   # deps.get + ecto.create/migrate/seed + assets
mix phx.server              # http://localhost:4000
```

`SECRET_KEY_BASE`, `PHX_SESSION_SIGNING_SALT` and `PHX_LIVE_SIGNING_SALT` are
required — the app refuses to boot in prod without them, and dev will complain.
Generate each with `mix phx.gen.secret` (the key base needs at least 64 bytes).
Everything else in `.env.example` is optional and degrades gracefully: no
`MAXMIND_LICENSE_KEY` simply means no IP geolocation, no LLM key means the bot
workers stay quiet, and so on. The one exception is `API_V1_TOKEN`: it is
optional to boot, but the `/api/v1` routes are fail-closed, so leaving it unset
turns them off entirely (every request gets a 401).

Dev-only routes are mounted when `dev_routes` is enabled: `/dev/dashboard`
(LiveDashboard) and `/dev/mailbox` (Swoosh preview).

### Common tasks

```bash
mix test                    # creates/migrates the test DB first
mix ecto.reset              # drop, recreate, migrate, seed
mix assets.build            # tailwind + esbuild, one-shot
mix assets.deploy           # minified + digested, for releases
mix gettext.extract --merge # refresh priv/gettext after touching translations
```

Note for WSL: there is no inotify, so Tailwind's watcher can miss new classes.
Run `mix tailwind colloq` after adding markup with classes that weren't already
in the build.

---

## Layout

```
lib/colloq/            contexts — one directory + one module per domain
lib/colloq/workers/    Oban workers (~35: bots, digests, scoring, pruning)
lib/colloq_web/live/   LiveViews, incl. forum_live/, user_live/, admin_live/
lib/colloq_web/channels/  forum, DM and notification channels
priv/repo/migrations/  numbered migrations; 000017 sets up ParadeDB search
assets/                JS and CSS sources
spam_classifier/       optional FastAPI + ONNX sidecar
systemd/               units for the app, Caddy, Postgres, backups, sidecar
test/                  ExUnit, with ExMachina factories and Mox
```

The contexts are the map of the feature set: `forum`, `accounts`, `messaging`,
`moderation`, `notifications`, `predictions`, `trust`, `badges`, `bots`,
`automations`, `reactions`, `bookmarks`, `subscriptions`, `media`, `emojis`,
`stickers`, `webhooks`, `site_settings`, plus the sports integrations
(`sofascore`, `copa_argentina`, `f1`).

### Notable pieces

- **Trust levels** (`Colloq.Trust`) gate what a user can do; promotion is
  automatic via `TrustPromotionWorker`.
- **Spam screening** runs only for TL0/TL1 posts, through `SpamDetectorWorker`
  → `Colloq.SpamClassifier` → the sidecar. Design notes in `spamdetector.md`.
- **Predictions** (`/predicciones`) score themselves once a fixture finishes,
  via `PredictionScorerWorker` and `PredictionRoundScorerWorker`.
- **Bots** respond to in-thread commands (`f1`, `clima`, `dolar`, `ca`,
  `sofascore`, `resultabot`) as Oban jobs, and an LLM responder handles
  mentions when a provider key is configured.
- **Admin** lives under `/admin`, split across moderator, admin and super-admin
  pipelines; super-admin routes additionally require 2FA.
- **External API** (`/api/v1`) is for webhook integrations — e.g. `POST
  /api/v1/automations/:id/trigger`. It has no browser session and no CSRF
  protection by design, so `ColloqWeb.Plugs.RequireApiToken` guards the whole
  pipeline: callers send `Authorization: Bearer $API_V1_TOKEN` and the token is
  compared in constant time. Generate it with `mix phx.gen.secret`. Session-aware
  JSON belongs elsewhere: `:browser_api` for reads, `:browser_api_write` for
  POST/DELETE (session + CSRF + auth), which is where the PWA push-subscription
  routes live.

---

## Deployment

Target is a single Debian/Ubuntu VPS running the Elixir release behind Caddy,
with Postgres and the sidecar on the same host. Secrets come from Infisical.

```bash
sudo ./install.sh    # one-time: runtimes, Postgres+ParadeDB, Caddy, podman, user, firewall
sudo ./setup.sh      # build + migrate + install units + restart + health check (re-runnable)
sudo ./doctor.sh     # read-only health check; exits 1 on any FAIL
sudo ./backup.sh     # pg_dump -Fc, prune, optional off-box copy (also runs on a timer)
sudo ./rollback.sh   # restore a previous release snapshot, no rebuild
```

Each script documents its own flags in the header comment — `setup.sh
--check`, `backup.sh --list`, `rollback.sh --list` and friends. `setup.sh` is
also the deploy path for subsequent releases, and snapshots the current release
before overwriting it so `rollback.sh` has something to go back to.

---

## Security

`security.md` is a standing security review, with findings graded
critical/high/medium/low, what's been fixed, and a suggested fix order. Read it
before deploying this anywhere real — several findings are still open.
