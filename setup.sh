#!/usr/bin/env bash
#
# setup.sh — install/update the Colloq application on a provisioned VPS.
#
# Run install.sh first (system packages, toolchain, service user, firewall).
# This script owns everything above that line and is safe to re-run: it is
# also the deploy path for subsequent releases.
#
#   sync source -> preflight secrets -> database -> build release
#   -> migrate -> install units -> restart -> health check
#
# Usage:
#   sudo ./setup.sh                  # full run from this checkout
#   sudo ./setup.sh --skip-build     # units/migrations only, reuse the release
#   sudo ./setup.sh --skip-migrate   # build and restart without migrating
#   sudo ./setup.sh --classifier     # also build/enable the spam-classifier sidecar
#   sudo ./setup.sh --check          # preflight only, change nothing
#
# Secrets come from Infisical, authenticated as the service user — the app's
# own runtime config raises on boot if the signing secrets are missing, so the
# preflight below checks for them rather than letting systemd crash-loop.

set -euo pipefail

APP_USER="${APP_USER:-colloq}"
APP_DIR="${APP_DIR:-/opt/colloq}"
SRC_DIR="${SRC_DIR:-$APP_DIR/src}"
DB_NAME="${DB_NAME:-colloq_prod}"
DB_USER="${DB_USER:-colloq}"
POSTGRES_MAJOR="${POSTGRES_MAJOR:-17}"
HEALTH_PORT="${HEALTH_PORT:-4000}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/lib/colloq/releases}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set by install.sh; sourced rather than guessed so there is one definition.
[[ -f /etc/profile.d/mise.sh ]] && source /etc/profile.d/mise.sh
export PATH="${MISE_DATA_DIR:-/usr/local/share/mise}/shims:$PATH"

SKIP_BUILD=0
SKIP_MIGRATE=0
WITH_CLASSIFIER=0
CHECK_ONLY=0

# Prints the header comment block — stops at the first line that isn't one, so
# it can't drift out of sync with the file.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)   SKIP_BUILD=1 ;;
    --skip-migrate) SKIP_MIGRATE=1 ;;
    --classifier)   WITH_CLASSIFIER=1 ;;
    --check)        CHECK_ONLY=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# The service runs as $APP_USER and reads secrets with that identity's
# Infisical credentials, so the build and migrations must use it too —
# otherwise they'd resolve a different set of secrets than production runs on.
# -s is required because the account has a nologin shell.
as_app() { runuser -s /bin/bash -u "$APP_USER" -- "$@"; }
as_app_sh() { runuser -s /bin/bash -u "$APP_USER" -c "$*"; }
as_pg() { runuser -u postgres -- "$@"; }

# --- preflight ----------------------------------------------------------------
REQUIRED_SECRETS=(SECRET_KEY_BASE PHX_SESSION_SIGNING_SALT PHX_LIVE_SIGNING_SALT DATABASE_URL PHX_HOST)

preflight() {
  step "Preflight"

  [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0)"
  id -u "$APP_USER" >/dev/null 2>&1 || die "user $APP_USER does not exist — run install.sh first"
  [[ -f "$REPO_DIR/mix.exs" ]] || die "$REPO_DIR does not look like the colloq checkout"

  local missing=()
  for cmd in mix elixir git rsync infisical psql systemctl; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "missing commands: ${missing[*]} — run install.sh first"
  ok "toolchain: $(elixir --version | tail -1)"

  systemctl is-active --quiet postgresql.service || die "postgresql.service is not running"
  ok "postgresql is up"
}

# Infisical resolves the project from .infisical.json in the working directory
# (unless INFISICAL_PROJECT_ID is exported), and these run as $APP_USER — who
# may have no read access to a root-owned checkout. Prefer the synced copy it
# definitely owns, falling back to the checkout on a first run.
secrets_cwd() {
  if [[ -f "$SRC_DIR/mix.exs" ]] && as_app test -r "$SRC_DIR/mix.exs"; then
    echo "$SRC_DIR"
  else
    echo "$REPO_DIR"
  fi
}

# Fail here, loudly, rather than let the release crash-loop under systemd with
# the real reason buried in journalctl.
preflight_secrets() {
  step "Secrets"

  local cwd
  cwd="$(secrets_cwd)"
  info "reading secrets as $APP_USER from $cwd"

  if ! as_app_sh "cd '$cwd' && infisical user get >/dev/null 2>&1"; then
    warn "could not confirm an Infisical session for $APP_USER"
    warn "authenticate with a machine identity, e.g.:"
    warn "  sudo runuser -s /bin/bash -u $APP_USER -- infisical login --method=universal-auth ..."
  fi

  local missing=()
  for var in "${REQUIRED_SECRETS[@]}"; do
    if ! as_app_sh "cd '$cwd' && infisical run --silent -- printenv $var >/dev/null 2>&1"; then
      missing+=("$var")
    fi
  done

  if (( ${#missing[@]} )); then
    die "Infisical is not providing: ${missing[*]}
    These are mandatory in prod — config/runtime.exs raises on boot without the
    signing secrets. Generate each with: mix phx.gen.secret"
  fi
  ok "all ${#REQUIRED_SECRETS[@]} required secrets resolve"

  # SECRET_KEY_BASE has a hard length floor in runtime.exs; catching it here
  # costs nothing and saves a confusing boot failure.
  local len
  len="$(as_app_sh "cd '$cwd' && infisical run --silent -- printenv SECRET_KEY_BASE" | tr -d '\n' | wc -c)"
  (( len >= 64 )) || die "SECRET_KEY_BASE is $len bytes; runtime.exs requires >= 64"
  ok "SECRET_KEY_BASE length ok ($len bytes)"
}

# --- source -------------------------------------------------------------------
sync_source() {
  step "Sync source to $SRC_DIR"

  install -d -o "$APP_USER" -g "$APP_USER" "$SRC_DIR"

  # _build and deps stay put so incremental deploys don't recompile the world.
  rsync -a --delete \
    --exclude '.git' --exclude '_build' --exclude 'deps' \
    --exclude 'node_modules' --exclude 'assets/node_modules' \
    --exclude '.env' --exclude 'priv/static/uploads' \
    "$REPO_DIR/" "$SRC_DIR/"

  chown -R "$APP_USER:$APP_USER" "$SRC_DIR"
  ok "source synced ($(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
}

# --- database -----------------------------------------------------------------
setup_database() {
  step "Database"

  if as_pg psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    ok "role $DB_USER exists"
  else
    local pw
    pw="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
    as_pg psql -qc "CREATE ROLE $DB_USER LOGIN PASSWORD '$pw'"
    warn "created role $DB_USER with a generated password:"
    warn "    $pw"
    warn "put it in DATABASE_URL in Infisical now — it is not stored anywhere else"
  fi

  if as_pg psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    ok "database $DB_NAME exists"
  else
    as_pg createdb -O "$DB_USER" "$DB_NAME"
    ok "created database $DB_NAME"
  fi

  # The migrations run CREATE EXTENSION, which needs privileges the app role
  # does not have — so create them here as superuser and let the migration's
  # IF NOT EXISTS turn into a no-op.
  for ext in unaccent pg_search; do
    if as_pg psql -d "$DB_NAME" -qc "CREATE EXTENSION IF NOT EXISTS $ext" 2>/dev/null; then
      ok "extension $ext ready"
    else
      warn "could not create extension '$ext'"
      [[ "$ext" == "pg_search" ]] && warn "install ParadeDB (see install.sh) — search migrations will fail without it"
    fi
  done
}

# --- build --------------------------------------------------------------------
# `mix release --overwrite` replaces the running release in place, so without
# this the previous build is simply gone and a bad deploy can only be undone by
# rebuilding an older commit. Archiving first is what makes rollback.sh work.
archive_current_release() {
  [[ -x "$APP_DIR/bin/colloq" ]] || return 0

  step "Archiving current release"
  install -d "$ARCHIVE_DIR"

  local snap="$ARCHIVE_DIR/$(date -u +%Y%m%dT%H%M%SZ)"
  # src/ is the source tree, not part of the release — copying it would double
  # the size of every snapshot for nothing.
  rsync -a --exclude 'src' "$APP_DIR/" "$snap/"
  (cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown revision") \
    > "$snap/.deployed_from"
  ok "archived as $(basename "$snap")"

  # Unbounded snapshots fill the disk; a handful is enough to walk back through.
  local extra
  extra="$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n "+$((KEEP_RELEASES + 1))")"
  if [[ -n "$extra" ]]; then
    echo "$extra" | while IFS= read -r old; do rm -rf "$old"; info "pruned $(basename "$old")"; done
  fi
}

build_release() {
  step "Build release"

  # Hex/rebar live in the building user's home, so they're per-account.
  as_app_sh "cd '$SRC_DIR' && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null"

  info "fetching prod dependencies…"
  as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod mix deps.get --only prod"

  info "compiling…"
  as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod mix compile"

  info "building assets (tailwind + esbuild + digest)…"
  as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod mix assets.setup"
  as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod mix assets.deploy"

  # Built under `infisical run` because mix.exs reads RELEASE_COOKIE at build
  # time — without it each build gets a fresh random cookie and no remote
  # console can attach to a running node.
  info "assembling release into $APP_DIR…"
  as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod infisical run --silent -- mix release --overwrite --path '$APP_DIR'"

  [[ -x "$APP_DIR/bin/colloq" ]] || die "release did not produce $APP_DIR/bin/colloq"
  ok "release built"
}

# --- migrations ---------------------------------------------------------------
# The release has no Colloq.Release module, so `bin/colloq eval` has nothing to
# call — migrations run through mix from the source tree instead. Worth adding
# that module later: it would let a shipped release migrate without needing the
# source and full toolchain on the box.
run_migrations() {
  step "Migrations"
  as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod infisical run --silent -- mix ecto.migrate"
  ok "migrations applied"
}

# --- services -----------------------------------------------------------------
install_units() {
  step "systemd units"

  install -m 0644 "$SRC_DIR/systemd/colloq.service" /etc/systemd/system/colloq.service
  ok "installed colloq.service"

  # postgresql.service and caddy.service in the repo describe how this host is
  # expected to run them; only overwrite the packaged units on request, since
  # replacing a distro unit silently is the kind of surprise that bites later.
  for unit in postgresql caddy; do
    if [[ -f "/etc/systemd/system/${unit}.service" ]]; then
      info "$unit.service already overridden locally — leaving it alone"
    else
      info "$unit.service: using the packaged unit (repo copy is reference only)"
    fi
  done

  systemctl daemon-reload
  systemctl enable colloq.service >/dev/null
  ok "colloq.service enabled"
}

install_classifier() {
  step "Spam-classifier sidecar"

  command -v podman >/dev/null || { warn "podman missing — skipping"; return; }

  as_app_sh "cd '$SRC_DIR' && podman build -t colloq-spam-classifier ./spam_classifier"

  local quadlet_dir="$APP_DIR/.config/containers/systemd"
  install -d -o "$APP_USER" -g "$APP_USER" "$quadlet_dir"
  install -o "$APP_USER" -g "$APP_USER" -m 0644 \
    "$SRC_DIR/systemd/colloq-spam-classifier.container" \
    "$quadlet_dir/colloq-spam-classifier.container"

  loginctl enable-linger "$APP_USER" 2>/dev/null || true
  as_app_sh "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user daemon-reload" || \
    warn "could not reload the user manager — run it as $APP_USER after logging in"

  ok "sidecar image and quadlet installed (listens on 127.0.0.1:8000)"
  info "point SPAM_ML_URL at http://127.0.0.1:8000 in Infisical"
}

restart_app() {
  step "Restart"
  systemctl restart colloq.service
  ok "colloq.service restarted"
}

health_check() {
  step "Health check"

  for i in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${HEALTH_PORT}/"; then
      ok "app responding on 127.0.0.1:${HEALTH_PORT}"
      return 0
    fi
    sleep 2
  done

  warn "no response on 127.0.0.1:${HEALTH_PORT} after 60s"
  warn "inspect with: journalctl -u colloq -n 100 --no-pager"
  return 1
}

summary() {
  cat <<EOF

${BOLD}Done.${RESET}

  status:  systemctl status colloq
  logs:    journalctl -u colloq -f
  console: sudo runuser -s /bin/bash -u $APP_USER -- $APP_DIR/bin/colloq remote

${BOLD}Still worth confirming on a first deploy:${RESET}
  * Caddy terminates TLS for PHX_HOST and proxies to 127.0.0.1:${HEALTH_PORT}.
  * Port ${HEALTH_PORT} is NOT reachable from outside — the endpoint trusts
    X-Forwarded-For, so direct access lets anyone forge the IP used for
    moderation (see lib/colloq_web/endpoint.ex).
  * If MEDIA_STORAGE=r2, add a Cloudflare Transform Rule on the bucket domain
    setting "content-security-policy: default-src 'none'; sandbox" and
    "x-content-type-options: nosniff" — uploads bypass the app's own headers there.
EOF
}

main() {
  preflight
  preflight_secrets

  if (( CHECK_ONLY )); then
    step "Check only — stopping before any change"
    exit 0
  fi

  sync_source
  setup_database
  (( SKIP_BUILD ))   || { archive_current_release; build_release; }
  (( SKIP_MIGRATE )) || run_migrations
  install_units
  (( WITH_CLASSIFIER )) && install_classifier
  restart_app
  health_check || true
  summary
}

main "$@"
