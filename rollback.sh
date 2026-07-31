#!/usr/bin/env bash
#
# rollback.sh — put a previous release back into service.
#
# setup.sh snapshots the current release into $ARCHIVE_DIR before overwriting
# it, so rolling back is a copy plus a restart. Nothing is rebuilt and nothing
# is fetched: this works when the network, the toolchain or the source tree are
# in no state to build.
#
# Usage:
#   sudo ./rollback.sh --list        # show available snapshots
#   sudo ./rollback.sh               # roll back to the most recent snapshot
#   sudo ./rollback.sh <name>        # roll back to a named snapshot
#
# IMPORTANT: this rolls back CODE, not the database. If the deploy you are
# undoing ran migrations, the schema stays migrated. That is usually fine —
# additive migrations are backward compatible — but a destructive one (dropped
# column, renamed table) will leave the older release broken. In that case
# restore a dump too: ./backup.sh --restore <file> --yes

set -euo pipefail

APP_USER="${APP_USER:-colloq}"
APP_DIR="${APP_DIR:-/opt/colloq}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/lib/colloq/releases}"
HEALTH_PORT="${HEALTH_PORT:-4000}"

MODE="rollback"
TARGET=""

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)    MODE="list" ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 2 ;;
    *)         TARGET="$1" ;;
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

snapshots() {
  [[ -d "$ARCHIVE_DIR" ]] || return 0
  find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

do_list() {
  step "Snapshots in $ARCHIVE_DIR"

  local any=0
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    any=1
    local marker=""
    [[ -f "$ARCHIVE_DIR/$s/.deployed_from" ]] && marker="$(cat "$ARCHIVE_DIR/$s/.deployed_from")"
    printf '    %-24s %8s  %s\n' "$s" \
      "$(du -sh "$ARCHIVE_DIR/$s" 2>/dev/null | cut -f1)" "$marker"
  done < <(snapshots)

  (( any )) || warn "no snapshots yet — setup.sh creates one on each deploy"
}

do_rollback() {
  [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0)"

  local target="$TARGET"
  if [[ -z "$target" ]]; then
    target="$(snapshots | head -1)"
    [[ -n "$target" ]] || die "no snapshots in $ARCHIVE_DIR — nothing to roll back to"
    info "most recent snapshot: $target"
  fi

  local src="$ARCHIVE_DIR/$target"
  [[ -d "$src" ]] || die "no such snapshot: $target (try --list)"
  [[ -x "$src/bin/colloq" ]] || die "$target does not contain a runnable release"

  step "Rolling back to $target"

  # Snapshot what's currently deployed first — a rollback to the wrong version
  # should itself be reversible.
  if [[ -x "$APP_DIR/bin/colloq" ]]; then
    local before="$ARCHIVE_DIR/before-rollback-$(date -u +%Y%m%dT%H%M%SZ)"
    install -d "$ARCHIVE_DIR"
    cp -a "$APP_DIR" "$before"
    echo "state before rolling back to $target" > "$before/.deployed_from"
    ok "current release archived as $(basename "$before")"
  fi

  systemctl stop colloq.service || warn "service was not running"

  # Replace contents rather than the directory itself: the unit's
  # WorkingDirectory points at $APP_DIR and src/ lives underneath it.
  find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name 'src' -exec rm -rf {} +
  cp -a "$src/." "$APP_DIR/"
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  ok "release files restored"

  systemctl start colloq.service
  ok "colloq.service started"

  step "Health check"
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${HEALTH_PORT}/"; then
      ok "app responding on 127.0.0.1:${HEALTH_PORT}"
      cat <<EOF

${BOLD}Rolled back to $target.${RESET}
Remember the database was NOT rolled back. If the bad deploy ran a destructive
migration, restore a dump as well: ./backup.sh --list
EOF
      return 0
    fi
    sleep 2
  done

  warn "no response after 60s — journalctl -u colloq -n 100 --no-pager"
  return 1
}

case "$MODE" in
  list)     do_list ;;
  rollback) do_rollback ;;
esac
