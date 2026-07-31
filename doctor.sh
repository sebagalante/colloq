#!/usr/bin/env bash
#
# doctor.sh — read-only health and configuration check for a Colloq VPS.
#
# Changes nothing. Run it after a deploy, when something looks wrong, or on a
# schedule. Every check prints PASS, WARN or FAIL; the exit code is 1 if any
# check FAILed, so it can gate a deploy or drive an alert.
#
# Usage:
#   sudo ./doctor.sh              # everything
#   sudo ./doctor.sh --quiet      # only WARN/FAIL lines
#   ./doctor.sh --no-secrets      # skip checks needing root/Infisical

set -uo pipefail   # deliberately no -e: a failing check must not abort the run

APP_USER="${APP_USER:-colloq}"
APP_DIR="${APP_DIR:-/opt/colloq}"
SRC_DIR="${SRC_DIR:-$APP_DIR/src}"
DB_NAME="${DB_NAME:-colloq_prod}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/colloq}"
HEALTH_PORT="${HEALTH_PORT:-4000}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-36}"

QUIET=0
NO_SECRETS=0

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)      QUIET=1 ;;
    --no-secrets) NO_SECRETS=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

FAILURES=0
WARNINGS=0

section() { (( QUIET )) || printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
pass() { (( QUIET )) || printf '  %s✓%s %-34s %s%s%s\n' "$GREEN" "$RESET" "$1" "$DIM" "${2:-}" "$RESET"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '  %s!%s %-34s %s\n' "$YELLOW" "$RESET" "$1" "${2:-}"; }
fail() { FAILURES=$((FAILURES+1)); printf '  %s✗%s %-34s %s\n' "$RED" "$RESET" "$1" "${2:-}"; }
note() { (( QUIET )) || printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }

as_app_sh() { runuser -s /bin/bash -u "$APP_USER" -c "$*"; }
as_pg() { runuser -u postgres -- "$@"; }
is_root() { [[ $EUID -eq 0 ]]; }

# --- services -----------------------------------------------------------------
check_services() {
  section "Services"

  for unit in colloq postgresql caddy; do
    if systemctl is-active --quiet "${unit}.service"; then
      pass "$unit.service" "active since $(systemctl show -p ActiveEnterTimestamp --value "${unit}.service" | cut -d' ' -f2-3)"
    elif systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
      fail "$unit.service" "not active — journalctl -u $unit -n 50"
    else
      warn "$unit.service" "not installed"
    fi
  done

  # Restart churn is the signature of a crash loop that systemd is papering
  # over. Only meaningful if the unit is actually installed.
  if [[ -f /etc/systemd/system/colloq.service ]]; then
    local restarts
    restarts="$(systemctl show -p NRestarts --value colloq.service 2>/dev/null || echo 0)"
    if [[ "${restarts:-0}" -gt 3 ]]; then
      warn "colloq restart count" "$restarts — check for a crash loop"
    else
      pass "colloq restart count" "$restarts"
    fi
  fi

  if systemctl list-timers colloq-backup.timer 2>/dev/null | grep -q colloq-backup; then
    pass "backup timer" "$(systemctl list-timers --no-pager colloq-backup.timer | awk 'NR==2 {print $1, $2}')"
  else
    warn "backup timer" "not enabled — systemctl enable --now colloq-backup.timer"
  fi
}

# --- application --------------------------------------------------------------
check_app() {
  section "Application"

  if [[ -x "$APP_DIR/bin/colloq" ]]; then
    pass "release present" "$APP_DIR/bin/colloq"
  else
    fail "release present" "missing — run setup.sh"
  fi

  local code
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${HEALTH_PORT}/" 2>/dev/null)"
  if [[ "$code" =~ ^(200|302)$ ]]; then
    pass "responds on loopback" "HTTP $code"
  else
    fail "responds on loopback" "no usable response on 127.0.0.1:${HEALTH_PORT}"
  fi

  if [[ -f "$SRC_DIR/.git/HEAD" || -d "$SRC_DIR" ]]; then
    local rev
    rev="$(cd "$SRC_DIR" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null)"
    [[ -n "$rev" ]] && pass "deployed revision" "$rev" || note "no git metadata in $SRC_DIR (expected — rsync excludes .git)"
  fi
}

# --- exposure -----------------------------------------------------------------
# The endpoint binds :: and RemoteIp rewrites remote_ip from X-Forwarded-For
# without verifying the sender, so anything that can reach the app port
# directly can choose the IP recorded for moderation. Caddy must be the only
# way in — this is the check that proves it.
check_exposure() {
  section "Network exposure"

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "firewall" "ufw active"
    if ufw status | grep -qE "^${HEALTH_PORT}\b"; then
      fail "app port firewalled" "an explicit ufw rule exposes ${HEALTH_PORT}"
    else
      pass "app port firewalled" "no rule opens ${HEALTH_PORT}"
    fi
  else
    warn "firewall" "ufw inactive or absent — verify ${HEALTH_PORT} is unreachable externally"
  fi

  # Prove it from the outside rather than inferring it from config.
  local public_ip
  public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
  if [[ -n "$public_ip" ]]; then
    if timeout 6 bash -c "</dev/tcp/${public_ip}/${HEALTH_PORT}" 2>/dev/null; then
      fail "app port reachable publicly" "${public_ip}:${HEALTH_PORT} accepted a connection"
    else
      pass "app port not public" "${public_ip}:${HEALTH_PORT} refused"
    fi
  else
    note "could not determine the public IP; skipped the external reachability probe"
  fi

  if ss -ltn 2>/dev/null | grep -qE ":(80|443)\s"; then
    pass "caddy listening" "80/443 bound"
  else
    warn "caddy listening" "nothing on 80/443"
  fi
}

# --- database -----------------------------------------------------------------
check_database() {
  section "Database"

  is_root || { note "skipped (needs root)"; return; }

  if as_pg psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
    pass "database exists" "$DB_NAME"
  else
    fail "database exists" "$DB_NAME not found"
    return
  fi

  for ext in unaccent pg_search; do
    if as_pg psql -d "$DB_NAME" -tAc "SELECT 1 FROM pg_extension WHERE extname='$ext'" 2>/dev/null | grep -q 1; then
      pass "extension $ext" "installed"
    else
      fail "extension $ext" "missing — search/migrations depend on it"
    fi
  done

  local size conns
  size="$(as_pg psql -tAc "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))" 2>/dev/null | tr -d ' ')"
  conns="$(as_pg psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='$DB_NAME'" 2>/dev/null | tr -d ' ')"
  pass "size / connections" "${size:-?} / ${conns:-?} open"

  # Pending migrations mean the running release and the schema disagree.
  if (( ! NO_SECRETS )) && [[ -f "$SRC_DIR/mix.exs" ]]; then
    local pending
    pending="$(as_app_sh "cd '$SRC_DIR' && MIX_ENV=prod infisical run --silent -- mix ecto.migrations 2>/dev/null" | grep -c '^\s*down' || true)"
    if [[ "${pending:-0}" -gt 0 ]]; then
      fail "pending migrations" "$pending not applied — run setup.sh"
    else
      pass "pending migrations" "none"
    fi
  fi
}

# --- secrets ------------------------------------------------------------------
check_secrets() {
  section "Secrets"

  if (( NO_SECRETS )) || ! is_root; then note "skipped"; return; fi

  command -v infisical >/dev/null || { fail "infisical CLI" "not installed"; return; }

  local cwd="$SRC_DIR"
  [[ -f "$cwd/mix.exs" ]] || cwd="."

  for var in SECRET_KEY_BASE PHX_SESSION_SIGNING_SALT PHX_LIVE_SIGNING_SALT DATABASE_URL PHX_HOST; do
    if as_app_sh "cd '$cwd' && infisical run --silent -- printenv $var >/dev/null 2>&1"; then
      pass "$var" "resolves"
    else
      fail "$var" "not provided by Infisical — the app cannot boot"
    fi
  done

  local len
  len="$(as_app_sh "cd '$cwd' && infisical run --silent -- printenv SECRET_KEY_BASE 2>/dev/null" | tr -d '\n' | wc -c)"
  if [[ "${len:-0}" -ge 64 ]]; then
    pass "SECRET_KEY_BASE length" "$len bytes"
  else
    fail "SECRET_KEY_BASE length" "$len bytes; runtime.exs requires >= 64"
  fi
}

# --- uploads ------------------------------------------------------------------
# Mirrors the upload hardening: locally-served files must carry the sandbox CSP,
# and R2-served files need the equivalent Cloudflare Transform Rule, which
# nothing in this repo can enforce.
check_uploads() {
  section "Upload security"

  local static_dir
  # In a release, priv lives at lib/colloq-<vsn>/priv.
  static_dir="$(find "$APP_DIR/lib" -maxdepth 4 -type d -path '*/priv/static' 2>/dev/null | head -1)"

  # The headers have to be observed on a request Plug.Static actually serves.
  # A missing path is no good: the router raises before the response is built
  # and the 404 comes back bare, which would look like a failure that isn't one.
  local sample=""
  [[ -n "$static_dir" && -d "$static_dir/uploads" ]] &&
    sample="$(find "$static_dir/uploads" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | head -1)"

  if [[ -z "$sample" ]]; then
    note "no stored uploads to probe — header enforcement unverified at runtime"
    note "(covered by test/colloq_web/plugs/upload_headers_test.exs)"
  else
    local hdrs
    hdrs="$(curl -sS -D- -o /dev/null --max-time 5 "http://127.0.0.1:${HEALTH_PORT}/uploads/${sample}" 2>/dev/null)"

    if grep -qi "content-security-policy:.*sandbox" <<<"$hdrs"; then
      pass "uploads sandboxed" "CSP sandbox present"
    else
      fail "uploads sandboxed" "no sandbox CSP on /uploads/${sample} — check ColloqWeb.Plugs.UploadHeaders"
    fi

    if grep -qi "x-content-type-options: *nosniff" <<<"$hdrs"; then
      pass "uploads nosniff" "present"
    else
      warn "uploads nosniff" "missing"
    fi
  fi

  # Files predating the hardening keep whatever extension they were stored with.
  if [[ -n "$static_dir" && -d "$static_dir/uploads" ]]; then
    local risky
    risky="$(find "$static_dir/uploads" -maxdepth 1 \( -name '*.html' -o -name '*.htm' -o -name '*.xhtml' \) 2>/dev/null | wc -l)"
    if [[ "${risky:-0}" -gt 0 ]]; then
      warn "legacy uploads" "$risky html-ish file(s) in uploads — review them"
    else
      pass "legacy uploads" "no html-ish files stored"
    fi
  fi

  if (( ! NO_SECRETS )) && is_root; then
    local base
    base="$(as_app_sh "cd '$SRC_DIR' 2>/dev/null && infisical run --silent -- printenv R2_PUBLIC_BASE_URL 2>/dev/null" || true)"
    if [[ -n "$base" ]]; then
      local cdn
      cdn="$(curl -sS -D- -o /dev/null --max-time 8 "${base%/}/" 2>/dev/null)"
      if grep -qi "content-security-policy:.*sandbox" <<<"$cdn"; then
        pass "CDN sandbox CSP" "Transform Rule active on ${base}"
      else
        warn "CDN sandbox CSP" "not seen on ${base} — add the Cloudflare Transform Rule"
      fi
    fi
  fi
}

# --- backups ------------------------------------------------------------------
check_backups() {
  section "Backups"

  if [[ ! -d "$BACKUP_DIR" ]]; then
    fail "backup directory" "$BACKUP_DIR does not exist — no backups have run"
    return
  fi

  local newest
  newest="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.dump' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"

  if [[ -z "$newest" ]]; then
    fail "recent backup" "no dumps in $BACKUP_DIR"
    return
  fi

  local age_h
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
  if (( age_h <= BACKUP_MAX_AGE_HOURS )); then
    pass "recent backup" "$(basename "$newest"), ${age_h}h old"
  else
    fail "recent backup" "newest is ${age_h}h old (limit ${BACKUP_MAX_AGE_HOURS}h)"
  fi

  if pg_restore --list "$newest" >/dev/null 2>&1; then
    pass "newest dump readable" "pg_restore can list it"
  else
    fail "newest dump readable" "the most recent backup is CORRUPT"
  fi
}

# --- host ---------------------------------------------------------------------
check_host() {
  section "Host"

  local used
  used="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
  if (( used >= 90 )); then
    fail "disk /" "${used}% used"
  elif (( used >= 75 )); then
    warn "disk /" "${used}% used"
  else
    pass "disk /" "${used}% used"
  fi

  local mem
  mem="$(free -m | awk '/^Mem:/ {printf "%d%%", $3/$2*100}')"
  pass "memory" "$mem used"
  pass "load" "$(cut -d' ' -f1-3 /proc/loadavg)"

  if command -v needrestart >/dev/null || [[ -f /var/run/reboot-required ]]; then
    [[ -f /var/run/reboot-required ]] && warn "pending reboot" "kernel/libc updated"
  fi
}

summary() {
  printf '\n%s────────────────────────────────%s\n' "$BOLD" "$RESET"
  if (( FAILURES )); then
    printf '%s%d failed%s, %d warning(s)\n' "$RED" "$FAILURES" "$RESET" "$WARNINGS"
    exit 1
  elif (( WARNINGS )); then
    printf '%sall checks passed%s with %d warning(s)\n' "$GREEN" "$RESET" "$WARNINGS"
  else
    printf '%sall checks passed%s\n' "$GREEN" "$RESET"
  fi
  exit 0
}

check_services
check_app
check_exposure
check_database
check_secrets
check_uploads
check_backups
check_host
summary
