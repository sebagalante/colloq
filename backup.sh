#!/usr/bin/env bash
#
# backup.sh — dump the Colloq database, prune old dumps, optionally ship a copy
# off the box.
#
# Designed to run unattended from systemd/colloq-backup.timer, and by hand when
# you want a dump before something risky. Dumps are pg_dump's custom format
# (-Fc): compressed, and restorable selectively with pg_restore.
#
# Usage:
#   sudo ./backup.sh                      # dump + prune
#   sudo ./backup.sh --list               # show what's on disk
#   sudo ./backup.sh --verify FILE        # check a dump is readable
#   sudo ./backup.sh --restore FILE --yes # DESTRUCTIVE: overwrite the database
#
# Off-box copies: set BACKUP_UPLOAD_CMD to any command taking the dump path as
# its single argument, e.g.
#   BACKUP_UPLOAD_CMD='rclone copy --config /etc/rclone.conf {} r2:colloq-backups/'
# The literal {} is replaced with the path. Left unset, backups stay local —
# which means a lost VPS is a lost database, so set it.

set -euo pipefail

APP_USER="${APP_USER:-colloq}"
DB_NAME="${DB_NAME:-colloq_prod}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/colloq}"
KEEP_DAYS="${KEEP_DAYS:-14}"
BACKUP_UPLOAD_CMD="${BACKUP_UPLOAD_CMD:-}"

MODE="backup"
TARGET=""
CONFIRMED=0

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)    MODE="list" ;;
    --verify)  MODE="verify"; TARGET="${2:-}"; shift ;;
    --restore) MODE="restore"; TARGET="${2:-}"; shift ;;
    --yes)     CONFIRMED=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
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

as_pg() { runuser -u postgres -- "$@"; }

require_root() { [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0)"; }

# --- backup -------------------------------------------------------------------
do_backup() {
  step "Backing up $DB_NAME"

  install -d -m 0700 "$BACKUP_DIR"

  local stamp file
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  file="$BACKUP_DIR/${DB_NAME}-${stamp}.dump"

  # Write to .partial first: a timer that fires during a reboot must never
  # leave a truncated file that looks like a usable backup.
  as_pg pg_dump -Fc -Z6 -d "$DB_NAME" -f "${file}.partial" \
    || die "pg_dump failed — nothing was written"
  mv "${file}.partial" "$file"
  chmod 0600 "$file"

  # Verify what we just wrote rather than trusting the exit code; a dump that
  # can't be read back is not a backup.
  pg_restore --list "$file" >/dev/null 2>&1 || die "dump is unreadable: $file"

  sha256sum "$file" | awk '{print $1}' > "${file}.sha256"
  ok "$(basename "$file") ($(du -h "$file" | cut -f1)), verified"

  upload "$file"
  prune
  report_freshness
}

upload() {
  local file="$1"

  if [[ -z "$BACKUP_UPLOAD_CMD" ]]; then
    warn "BACKUP_UPLOAD_CMD unset — this backup exists only on this machine"
    return
  fi

  step "Off-box copy"
  local cmd="${BACKUP_UPLOAD_CMD//\{\}/$file}"
  if bash -c "$cmd"; then
    ok "uploaded"
  else
    # Deliberately not fatal: a local dump that didn't ship still beats no dump,
    # and a failing timer that stops taking backups is the worse outcome.
    warn "upload failed — the local dump is still good"
  fi
}

prune() {
  step "Pruning dumps older than $KEEP_DAYS days"

  local removed=0
  while IFS= read -r -d '' old; do
    rm -f "$old" "${old}.sha256"
    info "removed $(basename "$old")"
    (( removed++ )) || true
  done < <(find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*.dump" -mtime "+$KEEP_DAYS" -print0)

  (( removed )) && ok "removed $removed old dump(s)" || ok "nothing to prune"
}

report_freshness() {
  local count size
  count="$(find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*.dump" | wc -l)"
  size="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
  ok "$count dump(s) on disk, $size total"
}

# --- inspect ------------------------------------------------------------------
do_list() {
  step "Dumps in $BACKUP_DIR"
  [[ -d "$BACKUP_DIR" ]] || die "$BACKUP_DIR does not exist — no backups have been taken"

  local found=0
  while IFS= read -r f; do
    found=1
    printf '    %-44s %8s  %s\n' "$(basename "$f")" \
      "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M')"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*.dump" | sort)

  (( found )) || warn "no dumps found"
}

do_verify() {
  step "Verifying $TARGET"
  [[ -f "$TARGET" ]] || die "no such file: $TARGET"

  pg_restore --list "$TARGET" >/dev/null 2>&1 || die "dump is corrupt or not a pg_dump archive"
  ok "archive is readable"

  if [[ -f "${TARGET}.sha256" ]]; then
    if sha256sum -c <(printf '%s  %s\n' "$(cat "${TARGET}.sha256")" "$TARGET") >/dev/null 2>&1; then
      ok "checksum matches"
    else
      die "CHECKSUM MISMATCH — this dump has been altered or damaged"
    fi
  else
    warn "no .sha256 alongside it — integrity unverified"
  fi

  local tables
  tables="$(pg_restore --list "$TARGET" | grep -c 'TABLE DATA' || true)"
  ok "contains $tables table(s) of data"
}

# --- restore ------------------------------------------------------------------
# Destructive and rare, so it is gated rather than convenient. The app is
# stopped first: restoring under a live release means connections holding the
# old schema while objects are dropped underneath them.
do_restore() {
  step "Restore from $TARGET"
  [[ -f "$TARGET" ]] || die "no such file: $TARGET"

  if (( ! CONFIRMED )); then
    die "this DROPS and recreates $DB_NAME. Re-run with --yes if that's what you want:
    $0 --restore $TARGET --yes"
  fi

  pg_restore --list "$TARGET" >/dev/null 2>&1 || die "refusing to restore an unreadable dump"

  warn "stopping colloq.service"
  systemctl stop colloq.service || warn "service was not running"

  # Safety net for the case this restore is itself the mistake.
  local safety="$BACKUP_DIR/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).dump"
  install -d -m 0700 "$BACKUP_DIR"
  if as_pg pg_dump -Fc -d "$DB_NAME" -f "$safety" 2>/dev/null; then
    ok "current database saved to $(basename "$safety")"
  else
    warn "could not snapshot the current database (does it exist?)"
  fi

  info "restoring…"
  as_pg pg_restore --clean --if-exists --no-owner --no-privileges \
    -d "$DB_NAME" "$TARGET" || warn "pg_restore reported errors — review the output above"

  systemctl start colloq.service
  ok "colloq.service started"
  info "check it came up: journalctl -u colloq -n 50 --no-pager"
}

main() {
  require_root
  case "$MODE" in
    backup)  do_backup ;;
    list)    do_list ;;
    verify)  [[ -n "$TARGET" ]] || die "--verify needs a file"; do_verify ;;
    restore) [[ -n "$TARGET" ]] || die "--restore needs a file"; do_restore ;;
  esac
}

main "$@"
