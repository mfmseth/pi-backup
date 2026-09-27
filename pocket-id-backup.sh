#!/bin/sh
# Pocket ID backup/restore through 1Password. Runs inside the pocket-id-backup
# image (Pocket ID's own image + the 1Password CLI), with Pocket ID's data
# volume mounted at /app/data. See README.md.
#
#   serve    (default) run `backup` on BACKUP_SCHEDULE (cron syntax, UTC)
#   backup   export -> upload as a dated 1Password document -> keep newest KEEP
#   restore  download the newest backup (or BACKUP_ID) and import it; refuses
#            if a database already exists unless FORCE=1
#   list     show the backups in 1Password, newest first
#
# Needs OP_SERVICE_ACCOUNT_TOKEN. ENCRYPTION_KEY is read from
# op://$OP_VAULT/pocket-id/encryption_key when not set.
set -eu
# Pocket ID finds its database relative to /app (data/pocket-id.db); cron
# starts jobs in /, where it would silently open a new, empty database.
cd /app

VAULT="${OP_VAULT:-homelab}"
TAG="${BACKUP_TAG:-pocket-id-backup}"
KEEP="${KEEP:-3}"
DB=/app/data/pocket-id.db

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) pocket-id-backup: $*"; }
die() { log "ERROR: $*"; exit 1; }

need_token() {
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "OP_SERVICE_ACCOUNT_TOKEN is not set"
}

load_key() {
  if [ -z "${ENCRYPTION_KEY:-}" ]; then
    ENCRYPTION_KEY=$(op read "op://$VAULT/pocket-id/encryption_key") \
      || die "cannot read op://$VAULT/pocket-id/encryption_key"
    export ENCRYPTION_KEY
  fi
}

# Backups as JSON, newest first.
backups() {
  op item list --vault "$VAULT" --tags "$TAG" --categories Document --format json \
    | jq 'sort_by(.created_at) | reverse'
}

backup() {
  need_token
  load_key
  umask 077
  ts=$(date -u +%Y-%m-%d_%H%M%S)
  f="/tmp/pocket-id-export-$ts.zip"
  trap 'rm -f "$f"' EXIT

  /app/pocket-id export --path "$f"
  # A usable export has a database.json with tables in it.
  unzip -p "$f" database.json | jq -e '.tables.users | length > 0' >/dev/null \
    || die "export looks empty or broken, not uploading"

  op document create "$f" --vault "$VAULT" --title "pocket-id-backup $ts" \
    --tags "$TAG" --file-name "$(basename "$f")" >/dev/null
  log "uploaded 'pocket-id-backup $ts' ($(wc -c <"$f") bytes)"

  # Only after a successful upload: delete all but the newest KEEP.
  for id in $(backups | jq -r ".[$KEEP:][] | .id"); do
    op item delete "$id" --vault "$VAULT"
    log "deleted old backup $id"
  done

  if [ -n "${PUSH_URL:-}" ]; then
    wget -q -O /dev/null "$PUSH_URL" && log "checked in with Uptime Kuma" \
      || log "WARNING: Uptime Kuma check-in failed (backup itself is fine)"
  fi
}

restore() {
  need_token
  load_key
  if [ -s "$DB" ] && [ "${FORCE:-}" != 1 ]; then
    die "$DB already exists. Stop pocket-id and run again with FORCE=1 to overwrite it."
  fi
  id="${BACKUP_ID:-$(backups | jq -r '.[0].id // empty')}"
  [ -n "$id" ] || die "no documents tagged '$TAG' in vault '$VAULT'"
  umask 077
  f=/tmp/pocket-id-restore.zip
  trap 'rm -f "$f"' EXIT
  op document get "$id" --vault "$VAULT" --out-file "$f" --force >/dev/null
  log "restoring $(op item get "$id" --vault "$VAULT" --format json | jq -r .title)"
  /app/pocket-id import --path "$f" --yes
  log "restore done -- start pocket-id now"
}

list() {
  need_token
  backups | jq -r '.[] | "\(.created_at)  \(.id)  \(.title)"'
}

serve() {
  need_token
  schedule="${BACKUP_SCHEDULE:-15 7 * * *}"
  # busybox crond doesn't pass the container's environment to jobs.
  (umask 077; export -p >/run/pocket-id-backup.env)
  echo "$schedule . /run/pocket-id-backup.env; /usr/local/bin/pocket-id-backup backup >/proc/1/fd/1 2>&1" \
    >/etc/crontabs/root
  log "backing up on '$schedule' (UTC), keeping the newest $KEEP in 1Password vault '$VAULT'"
  exec crond -f -l 8
}

case "${1:-serve}" in
  serve | backup | restore | list) "${1:-serve}" ;;
  *) die "usage: pocket-id-backup [serve|backup|restore|list]" ;;
esac
