#!/usr/bin/env bash
#
# install.sh — one-time provisioning of a fresh VPS for Colloq.
#
# Installs system-level dependencies only: language runtimes, PostgreSQL with
# ParadeDB, Caddy, podman, the Infisical CLI, the service user and the
# firewall. It does NOT touch the application — that's setup.sh, which is
# re-runnable and does the build, migrations and service install.
#
# Assumptions (checked where cheap):
#   * Debian 12/13 or Ubuntu 22.04+ on x86_64. The systemd units in systemd/
#     already bake in the Debian layout (/usr/lib/postgresql/17/main).
#   * Run as root on a machine you're happy to modify.
#
# Idempotent: every step checks for its own result first, so re-running after a
# failure resumes rather than duplicating work.
#
# Usage:
#   sudo ./install.sh              # provision everything
#   sudo ./install.sh --dry-run    # print what would happen, change nothing

set -euo pipefail

# --- versions -----------------------------------------------------------------
# Pinned to what the project is developed against; `mix.exs` requires ~> 1.18.
ELIXIR_VERSION="${ELIXIR_VERSION:-1.20.2}"
OTP_VERSION="${OTP_VERSION:-28.1}"
NODE_MAJOR="${NODE_MAJOR:-22}"
POSTGRES_MAJOR="${POSTGRES_MAJOR:-17}"

# ParadeDB ships pg_search as a .deb per Postgres major version. There is no
# apt repo, so point this at the release asset matching POSTGRES_MAJOR and this
# machine's architecture: https://github.com/paradedb/paradedb/releases
PARADEDB_DEB_URL="${PARADEDB_DEB_URL:-}"

APP_USER="${APP_USER:-colloq}"
APP_DIR="${APP_DIR:-/opt/colloq}"
SRC_DIR="${SRC_DIR:-$APP_DIR/src}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
# Prints the header comment block — stops at the first line that isn't one, so
# it can't drift out of sync with the file.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

# --- output -------------------------------------------------------------------
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

run() {
  if (( DRY_RUN )); then
    printf '    %s[dry-run]%s %s\n' "$YELLOW" "$RESET" "$*"
  else
    "$@"
  fi
}

# --- preflight ----------------------------------------------------------------
preflight() {
  step "Preflight"

  [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0)"

  command -v apt-get >/dev/null || die "no apt-get — this script targets Debian/Ubuntu"

  local id="unknown"
  [[ -r /etc/os-release ]] && id="$(. /etc/os-release && echo "${ID:-unknown}")"
  case "$id" in
    debian|ubuntu) ok "distro: $id" ;;
    *) warn "distro '$id' is untested; the systemd units assume Debian paths" ;;
  esac

  ok "arch: $(dpkg --print-architecture)"
}

# --- system packages ----------------------------------------------------------
# Erlang is built from source by mise, so the -dev headers are not optional:
# without them the build silently produces a runtime with no crypto or no
# ncurses, which fails much later and confusingly.
base_packages() {
  step "Base packages"

  local pkgs=(
    ca-certificates curl gnupg git unzip rsync
    build-essential automake autoconf pkg-config
    libssl-dev libncurses5-dev libwxgtk3.2-dev
    libgl1-mesa-dev libglu1-mesa-dev libpng-dev
    libsctp1 libsctp-dev
    inotify-tools ufw
  )

  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  ok "base packages installed"
}

# --- runtimes -----------------------------------------------------------------
# mise manages Erlang + Elixir, installed into shared system paths rather than
# root's home: setup.sh builds as the unprivileged colloq user, and a toolchain
# under /root would be unreadable to it. MISE_DATA_DIR fixes the shim path at a
# location both accounts can use, which is why it's exported globally.
export MISE_DATA_DIR=/usr/local/share/mise
export MISE_CONFIG_DIR=/etc/mise
MISE_SHIMS="$MISE_DATA_DIR/shims"

install_mise() {
  step "mise (Erlang/Elixir version manager)"

  if command -v mise >/dev/null; then
    ok "mise already present: $(mise --version 2>/dev/null | head -1)"
  else
    run bash -c 'curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh'
    command -v mise >/dev/null || (( DRY_RUN )) || die "mise install did not produce /usr/local/bin/mise"
    ok "mise installed"
  fi

  # One file that both login shells and setup.sh source, so there is a single
  # definition of where the toolchain lives.
  if [[ ! -f /etc/profile.d/mise.sh ]]; then
    run bash -c "cat > /etc/profile.d/mise.sh <<'PROFILE'
export MISE_DATA_DIR=/usr/local/share/mise
export MISE_CONFIG_DIR=/etc/mise
export PATH=\"/usr/local/share/mise/shims:\$PATH\"
PROFILE"
    ok "mise exported for login shells"
  fi

  run install -d -m 0755 "$MISE_DATA_DIR" "$MISE_CONFIG_DIR"
}

install_beam() {
  step "Erlang/OTP $OTP_VERSION + Elixir $ELIXIR_VERSION"
  info "Erlang compiles from source here — expect 10-25 minutes on a small VPS."

  run mise use --global "erlang@${OTP_VERSION}"
  run mise use --global "elixir@${ELIXIR_VERSION}"
  run mise install

  if (( ! DRY_RUN )); then
    export PATH="$MISE_SHIMS:$PATH"
    mix local.hex --force >/dev/null
    mix local.rebar --force >/dev/null
    # World-readable so the colloq user can build against the same toolchain.
    chmod -R a+rX "$MISE_DATA_DIR"
  fi
  ok "BEAM toolchain ready at $MISE_SHIMS"
}

install_node() {
  step "Node.js $NODE_MAJOR (needed by mix assets.setup)"

  if command -v node >/dev/null && [[ "$(node -v)" == v${NODE_MAJOR}.* ]]; then
    ok "node already present: $(node -v)"
    return
  fi

  run bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  ok "node installed"
}

# --- database -----------------------------------------------------------------
install_postgres() {
  step "PostgreSQL $POSTGRES_MAJOR"

  if [[ -d "/usr/lib/postgresql/${POSTGRES_MAJOR}" ]]; then
    ok "postgresql $POSTGRES_MAJOR already installed"
  else
    # PGDG carries the exact major the systemd unit hardcodes; distro repos
    # lag and would land the cluster in a differently-numbered directory.
    run install -d /usr/share/postgresql-common/pgdg
    run bash -c 'curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc'
    run bash -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list'
    run apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      "postgresql-${POSTGRES_MAJOR}" "postgresql-contrib-${POSTGRES_MAJOR}" libpq-dev
    ok "postgresql $POSTGRES_MAJOR installed"
  fi

  # `unaccent` is contrib and ships with the server package; the migrations
  # only need CREATE EXTENSION, which setup.sh runs.
  ok "unaccent available via postgresql-contrib"
}

install_paradedb() {
  step "ParadeDB (pg_search)"

  if (( DRY_RUN )); then
    info "[dry-run] would install pg_search from \$PARADEDB_DEB_URL"
    return
  fi

  if [[ -f "/usr/lib/postgresql/${POSTGRES_MAJOR}/lib/pg_search.so" ]]; then
    ok "pg_search already installed"
  elif [[ -z "$PARADEDB_DEB_URL" ]]; then
    warn "PARADEDB_DEB_URL is not set — skipping pg_search."
    warn "The search migrations (CREATE EXTENSION pg_search) will FAIL without it."
    warn "Grab the .deb for postgres ${POSTGRES_MAJOR}/$(dpkg --print-architecture) from"
    warn "  https://github.com/paradedb/paradedb/releases"
    warn "then re-run: PARADEDB_DEB_URL=<url> sudo $0"
    return
  else
    local deb="/tmp/paradedb.deb"
    curl -fsSL "$PARADEDB_DEB_URL" -o "$deb" || die "could not download $PARADEDB_DEB_URL"
    env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
    rm -f "$deb"
    ok "pg_search installed"
  fi

  # pg_search registers a background worker, so it has to be preloaded — the
  # extension will not create cleanly otherwise.
  local conf="/etc/postgresql/${POSTGRES_MAJOR}/main/postgresql.conf"
  if [[ -f "$conf" ]] && ! grep -qE "^\s*shared_preload_libraries.*pg_search" "$conf"; then
    warn "shared_preload_libraries does not list pg_search in $conf"
    warn "add it and restart postgres, or CREATE EXTENSION pg_search may fail"
  fi
}

# --- reverse proxy, secrets, containers ---------------------------------------
install_caddy() {
  step "Caddy"

  if command -v caddy >/dev/null; then
    ok "caddy already present: $(caddy version | head -1)"
    return
  fi

  run bash -c 'curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg'
  run bash -c 'curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list'
  run apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
  ok "caddy installed"

  # The unit in systemd/ points at /etc/caddy/Caddyfile but the repo ships no
  # Caddyfile — TLS and the reverse-proxy target are deploy-specific.
  [[ -f /etc/caddy/Caddyfile ]] || warn "/etc/caddy/Caddyfile does not exist yet — see the note at the end"
}

install_infisical() {
  step "Infisical CLI"

  if command -v infisical >/dev/null; then
    ok "infisical already present"
  else
    run bash -c 'curl -1sLf https://artifacts-cli.infisical.com/setup.deb.sh | bash'
    run apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y infisical
  fi

  # systemd/colloq.service hardcodes /usr/local/bin/infisical; the package
  # installs to /usr/bin. Symlink rather than edit the unit, so the repo copy
  # stays the source of truth.
  if (( ! DRY_RUN )) && [[ ! -e /usr/local/bin/infisical ]] && command -v infisical >/dev/null; then
    ln -sf "$(command -v infisical)" /usr/local/bin/infisical
    ok "linked $(command -v infisical) -> /usr/local/bin/infisical (path the unit expects)"
  fi
}

install_podman() {
  step "podman (spam-classifier sidecar)"

  if command -v podman >/dev/null; then
    ok "podman already present: $(podman --version)"
  else
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y podman
    ok "podman installed"
  fi

  # The Quadlet unit is rootless and user-level, so it dies with the login
  # session unless lingering is on.
  if (( ! DRY_RUN )) && id -u "$APP_USER" >/dev/null 2>&1; then
    loginctl enable-linger "$APP_USER" 2>/dev/null && ok "lingering enabled for $APP_USER" || true
  fi
}

# --- service account ----------------------------------------------------------
create_user() {
  step "Service account and directories"

  if id -u "$APP_USER" >/dev/null 2>&1; then
    ok "user $APP_USER already exists"
  else
    run adduser --system --group --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
    ok "created system user $APP_USER"
  fi

  run install -d -o "$APP_USER" -g "$APP_USER" -m 0755 "$APP_DIR" "$SRC_DIR"
  ok "$APP_DIR and $SRC_DIR ready"
}

# --- firewall -----------------------------------------------------------------
# This is load-bearing, not hygiene. ColloqWeb.Endpoint binds :: on PORT and
# RemoteIp rewrites remote_ip from X-Forwarded-For without verifying the sender
# (see the SECURITY comment in lib/colloq_web/endpoint.ex). Anything that can
# reach 4000 directly can therefore choose the IP recorded for moderation —
# so only Caddy may talk to it.
configure_firewall() {
  step "Firewall"

  if ! command -v ufw >/dev/null; then
    warn "ufw not installed — ensure port 4000 is not reachable from the internet"
    return
  fi

  run ufw allow OpenSSH
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  run ufw --force enable

  if (( ! DRY_RUN )) && ufw status | grep -qE '^4000'; then
    warn "an explicit rule for 4000 exists — remove it unless you meant it"
  fi
  ok "22/80/443 open; app port stays private to Caddy on loopback"
}

enable_services() {
  step "System services"
  run systemctl enable --now postgresql.service || warn "could not enable postgresql.service"
  run systemctl enable --now caddy.service || warn "could not enable caddy.service (Caddyfile missing?)"
}

summary() {
  cat <<EOF

${BOLD}Provisioning complete.${RESET}

Before running setup.sh you still need to, by hand:

  1. ${BOLD}Write /etc/caddy/Caddyfile${RESET} — not in the repo, since the domain and TLS
     settings are deploy-specific. It must reverse_proxy to 127.0.0.1:4000
     and set X-Forwarded-For / X-Forwarded-Proto (Caddy does both by default).

  2. ${BOLD}Authenticate Infisical${RESET} as $APP_USER so the service can read secrets
     unattended — a machine identity, not your personal login:
         infisical login --method=universal-auth --client-id=... --client-secret=...
     Then confirm: infisical run -- printenv SECRET_KEY_BASE

  3. ${BOLD}Set the secrets that must exist in prod${RESET} or the app refuses to boot:
     SECRET_KEY_BASE (>= 64 bytes), PHX_SESSION_SIGNING_SALT, PHX_LIVE_SIGNING_SALT,
     DATABASE_URL, PHX_HOST. Generate each with: mix phx.gen.secret

  4. ${BOLD}Point PARADEDB_DEB_URL at a release${RESET} and re-run this script if the
     pg_search step warned — full-text search migrations depend on it.

Then: ${BOLD}sudo ./setup.sh${RESET}
EOF
}

main() {
  (( DRY_RUN )) && warn "dry run — no changes will be made"
  preflight
  base_packages
  install_mise
  install_beam
  install_node
  install_postgres
  install_paradedb
  install_caddy
  install_infisical
  create_user
  install_podman
  configure_firewall
  enable_services
  summary
}

main "$@"
