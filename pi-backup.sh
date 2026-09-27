#!/bin/sh
# Nightly backups of pi's app state that git doesn't cover, to 1Password.
# Runs in the pi-backup image; see README.md.
#
#   serve                 (default) run `backup` on BACKUP_SCHEDULE (cron, UTC)
#   backup                back up every target, keep the newest KEEP of each
#   restore <target>      put the newest backup (or BACKUP_ID) back; refuses
#                         to overwrite existing data unless FORCE=1
#   list                  show the backups in 1Password, newest first
#
# Targets:
#   pocket-id   Pocket ID (users, passkeys, groups, OIDC clients, signing keys)
#               via `pocket-id export`, with the pocket-id binary copied from
#               the same image version pi runs; volume at /pocket-id/data.
#               ENCRYPTION_KEY comes from op://$OP_VAULT/pocket-id/encryption_key
#   arcane      Arcane's SQLite database (volume at /arcane), copied with
#               SQLite's online backup and integrity-checked
#   technitium  Technitium's config (/etc/dns), minus stats, logs, cache and
#               downloadable block lists
set -eu

VAULT="${OP_VAULT:-homelab}"
KEEP="${KEEP:-3}"
ALL_TARGETS="pocket-id arcane technitium"
# Back up a subset with e.g. TARGETS="pocket-id technitium".
TARGETS="${TARGETS:-$ALL_TARGETS}"
TMP=/tmp/pi-backup

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) pi-backup: $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "OP_SERVICE_ACCOUNT_TOKEN is not set"

# Backups of one target as JSON, newest first.
backups() {
  op item list --vault "$VAULT" --tags "$1-backup" --categories Document --format json \
    | jq 'sort_by(.created_at) | reverse'
}

upload() { # target file
  ts=$(date -u +%Y-%m-%d_%H%M%S)
  ext="${2#*.}"
  op document create "$2" --vault "$VAULT" --title "$1-backup $ts" \
    --tags "$1-backup" --file-name "$1-$ts.$ext" >/dev/null
  log "uploaded '$1-backup $ts' ($(wc -c <"$2") bytes)"
  # Only after a successful upload: delete all but the newest KEEP.
  for id in $(backups "$1" | jq -r ".[$KEEP:][] | .id"); do
    op item delete "$id" --vault "$VAULT"
    log "deleted old $1 backup $id"
  done
}

# Pocket ID resolves data/pocket-id.db relative to the working directory; run
# anywhere else and it silently opens a new, empty database.
pocket_id_env() {
  cd /pocket-id
  if [ -z "${ENCRYPTION_KEY:-}" ]; then
    ENCRYPTION_KEY=$(op read "op://$VAULT/pocket-id/encryption_key") \
      || die "pocket-id: cannot read op://$VAULT/pocket-id/encryption_key"
    export ENCRYPTION_KEY
  fi
}

backup_pocket_id() {
  [ -s /pocket-id/data/pocket-id.db ] || die "pocket-id: /pocket-id/data/pocket-id.db not found"
  pocket_id_env
  pocket-id export --path "$TMP/pocket-id.zip"
  # A usable export has users in database.json; refuse to upload anything else.
  unzip -p "$TMP/pocket-id.zip" database.json | jq -e '.tables.users | length > 0' >/dev/null \
    || die "pocket-id: export looks empty or broken, not uploading"
  upload pocket-id "$TMP/pocket-id.zip"
}

backup_arcane() {
  [ -s /arcane/arcane.db ] || die "arcane: /arcane/arcane.db not found"
  rm -f "$TMP/arcane.db"
  sqlite3 /arcane/arcane.db ".backup '$TMP/arcane.db'"
  [ "$(sqlite3 "$TMP/arcane.db" 'PRAGMA integrity_check;')" = ok ] \
    || die "arcane: backup copy failed its integrity check"
  gzip -9 -f "$TMP/arcane.db"
  upload arcane "$TMP/arcane.db.gz"
}

backup_technitium() {
  [ -s /etc/dns/dns.config ] || die "technitium: /etc/dns/dns.config not found"
  tar -C /etc/dns -czf "$TMP/technitium.tar.gz" \
    --exclude=./stats --exclude=./logs --exclude=./cache.bin --exclude=./blocklists .
  tar -tzf "$TMP/technitium.tar.gz" | grep -qx './dns.config' \
    || die "technitium: archive has no dns.config"
  upload technitium "$TMP/technitium.tar.gz"
}

backup() {
  umask 077
  mkdir -p "$TMP"
  trap 'rm -rf "$TMP"' EXIT
  failed=""
  for t in $TARGETS; do
    # A separate process, not a ( ) subshell: `set -e` is ignored inside
    # anything on the left of `||`, so a failed upload could go on to prune.
    "$0" _one "$t" || failed="$failed $t"
  done
  [ -z "$failed" ] || die "failed:$failed (no Uptime Kuma check-in)"
  if [ -n "${PUSH_URL:-}" ]; then
    wget -q -O /dev/null "$PUSH_URL" && log "checked in with Uptime Kuma" \
      || log "WARNING: Uptime Kuma check-in failed (backups themselves are fine)"
  fi
}

restore() {
  t="${1:-}"
  case " $ALL_TARGETS " in *" $t "*) ;; *) die "usage: pi-backup restore <$(echo $ALL_TARGETS | tr ' ' '|')>" ;; esac
  id="${BACKUP_ID:-$(backups "$t" | jq -r '.[0].id // empty')}"
  [ -n "$id" ] || die "no documents tagged '$t-backup' in vault '$VAULT'"
  umask 077
  mkdir -p "$TMP"
  trap 'rm -rf "$TMP"' EXIT
  f="$TMP/restore"
  op document get "$id" --vault "$VAULT" --out-file "$f" --force >/dev/null
  log "restoring $(op item get "$id" --vault "$VAULT" --format json | jq -r .title)"
  case "$t" in
    pocket-id)
      if [ -s /pocket-id/data/pocket-id.db ] && [ "${FORCE:-}" != 1 ]; then
        die "/pocket-id/data/pocket-id.db already exists. Stop pocket-id and run again with FORCE=1."
      fi
      pocket_id_env
      pocket-id import --path "$f" --yes
      ;;
    arcane)
      if [ -s /arcane/arcane.db ] && [ "${FORCE:-}" != 1 ]; then
        die "/arcane/arcane.db already exists. Stop arcane and run again with FORCE=1."
      fi
      rm -f /arcane/arcane.db-wal /arcane/arcane.db-shm
      gunzip -c "$f" >/arcane/arcane.db
      chown 65532:65532 /arcane/arcane.db  # Arcane runs as 65532
      ;;
    technitium)
      if [ -s /etc/dns/dns.config ] && [ "${FORCE:-}" != 1 ]; then
        die "/etc/dns/dns.config already exists. Stop technitium and run again with FORCE=1."
      fi
      tar -C /etc/dns -xzpf "$f"
      ;;
  esac
  log "restore done -- start $t now"
}

list() {
  for t in $TARGETS; do
    backups "$t" | jq -r '.[] | "\(.created_at)  \(.id)  \(.title)"'
  done
}

serve() {
  schedule="${BACKUP_SCHEDULE:-25 7 * * *}"
  # busybox crond doesn't pass the container's environment to jobs.
  (umask 077; export -p >/run/pi-backup.env)
  echo "$schedule . /run/pi-backup.env; /usr/local/bin/pi-backup backup >/proc/1/fd/1 2>&1" \
    >/etc/crontabs/root
  log "backing up [$TARGETS] on '$schedule' (UTC), keeping the newest $KEEP of each in vault '$VAULT'"
  exec crond -f -l 8
}

cmd="${1:-serve}"
[ $# -gt 0 ] && shift
case "$cmd" in
  serve | backup | list) "$cmd" ;;
  _one) umask 077; mkdir -p "$TMP"; "backup_$(echo "$1" | tr - _)" ;;
  restore) restore "$@" ;;
  *) die "usage: pi-backup [serve|backup|restore <target>|list]" ;;
esac
