#!/bin/sh
# Nightly backups of pi's app state that git doesn't cover, encrypted with age
# and uploaded to Cloudflare R2. Runs in the pi-backup image; see README.md.
#
#   serve                 (default) run `backup` on BACKUP_SCHEDULE (cron, UTC)
#   backup                back up every target, keep the newest KEEP of each
#   restore <target>      put the newest backup (or BACKUP_ID) back; refuses
#                         to overwrite existing data unless FORCE=1
#   list                  show the backups in each target's bucket, newest first
#
# Targets:
#   pocket-id   Pocket ID (users, passkeys, groups, OIDC clients, signing keys)
#               via `pocket-id export`, with the pocket-id binary copied from
#               the same image version pi runs; volume at /pocket-id/data.
#               ENCRYPTION_KEY comes from op://$OP_VAULT/pocket-id/encryption_key
#   technitium  Technitium's config (/etc/dns), minus stats, logs, cache and
#               downloadable block lists
#
# Each target has its own bucket, <S3_BUCKET_PREFIX>-<target>. Each backup is
# encrypted to an age public key and stored there as
# <target>-<UTC timestamp>.<ext>.age. Backing up needs only
# the public key; restoring needs the private key. Anything not set in the
# environment is read from 1Password with OP_SERVICE_ACCOUNT_TOKEN.
set -eu

VAULT="${OP_VAULT:-homelab}"
KEEP="${KEEP:-14}"
R2_ITEM="${R2_ITEM:-cloudflare-r2-pi-backup}"
AGE_ITEM="${AGE_ITEM:-pi-backup-age}"
ALL_TARGETS="pocket-id technitium"
# Back up a subset with e.g. TARGETS="pocket-id technitium".
TARGETS="${TARGETS:-$ALL_TARGETS}"
TMP=/tmp/pi-backup

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) pi-backup: $*"; }
die() {
  log "ERROR: $*" >&2
  # During `backup`, tell Uptime Kuma right away instead of just not checking in.
  [ -z "${in_backup:-}" ] || push down "$*" || true
  exit 1
}

# Report to Uptime Kuma's push monitor: push up|down <message>. PUSH_URL's own
# status/msg parameters are replaced.
push() {
  [ -n "${PUSH_URL:-}" ] || return 0
  msg=$(printf '%s' "$2" | sed 's/%/%25/g; s/ /%20/g; s/:/%3A/g; s/&/%26/g; s/#/%23/g; s/?/%3F/g')
  wget -q -O /dev/null "${PUSH_URL%%\?*}?status=$1&msg=$msg"
}

case "$KEEP" in '' | *[!0-9]* | 0) die "KEEP must be a whole number of at least 1" ;; esac

op_read() { # op:// reference
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "OP_SERVICE_ACCOUNT_TOKEN is not set (needed to read $1)"
  op read "$1" || die "cannot read $1"
}

# rclone remote `r2:` from S3_* or, for whatever isn't set, the 1Password item
# R2_ITEM (fields access_key_id, secret_access_key, account_id). Read
# once in `backup`, then inherited by each target's process.
storage() {
  [ -z "${RCLONE_CONFIG_R2_TYPE:-}" ] || return 0
  if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ -z "${S3_SECRET_ACCESS_KEY:-}" ] \
    || [ -z "${S3_ENDPOINT:-}" ]; then
    [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] \
      || die "OP_SERVICE_ACCOUNT_TOKEN is not set (needed to read op://$VAULT/$R2_ITEM)"
    item=$(op item get "$R2_ITEM" --vault "$VAULT" --reveal --format json) \
      || die "cannot read 1Password item '$R2_ITEM' in vault '$VAULT'"
    field() { printf '%s' "$item" | jq -r --arg l "$1" '[.fields[] | select(.label == $l) | .value][0] // empty'; }
    : "${S3_ACCESS_KEY_ID:=$(field access_key_id)}"
    : "${S3_SECRET_ACCESS_KEY:=$(field secret_access_key)}"
    : "${S3_ENDPOINT:=https://$(field account_id).r2.cloudflarestorage.com}"
  fi
  for v in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_ENDPOINT; do
    eval "val=\$$v"
    case "$val" in '' | *REPLACE_WITH* | https://.r2.*)
      die "$v is empty or still a placeholder (1Password item '$R2_ITEM')" ;;
    esac
  done
  # No config file: the remote is defined entirely by these variables.
  export RCLONE_CONFIG=/dev/null \
    RCLONE_CONFIG_R2_TYPE=s3 \
    RCLONE_CONFIG_R2_PROVIDER="${S3_PROVIDER:-Cloudflare}" \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_R2_ENDPOINT="$S3_ENDPOINT" \
    RCLONE_CONFIG_R2_REGION="${S3_REGION:-auto}" \
    RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

# A target's bucket, as an rclone path.
bucket() { echo "r2:${S3_BUCKET_PREFIX:-pi-backup}-$1"; }

# Backups of one target, newest first: "<name>" (or "<name>  <size>" with -s).
backups() { # [-s] target
  fmt=p
  [ "$1" = -s ] && { fmt=ps; shift; }
  objs=$(rclone lsf --files-only --format "$fmt" --separator '  ' "$(bucket "$1")") \
    || die "$1: cannot list $(bucket "$1")"
  printf '%s\n' "$objs" | grep -E "^$1-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\..+\.age( |\$)" | sort -r
}

upload() { # target file
  ts=$(date -u +%Y-%m-%d_%H%M%S)
  name="$1-$ts.${2#*.}.age"
  age -r "$AGE_RECIPIENT" -o "$2.age" "$2"
  rclone copyto "$2.age" "$(bucket "$1")/$name"
  log "uploaded $1/$name ($(wc -c <"$2.age") bytes)"
  # Only after a successful upload: delete all but the newest KEEP.
  all=$(backups "$1")
  for o in $(printf '%s\n' "$all" | tail -n +$((KEEP + 1))); do
    rclone deletefile "$(bucket "$1")/$o"
    log "deleted old backup $1/$o"
  done
}

# Pocket ID resolves data/pocket-id.db relative to the working directory; run
# anywhere else and it silently opens a new, empty database.
pocket_id_env() {
  cd /pocket-id
  if [ -z "${ENCRYPTION_KEY:-}" ]; then
    ENCRYPTION_KEY=$(op_read "op://$VAULT/pocket-id/encryption_key")
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

backup_technitium() {
  [ -s /etc/dns/dns.config ] || die "technitium: /etc/dns/dns.config not found"
  tar -C /etc/dns -czf "$TMP/technitium.tar.gz" \
    --exclude=./stats --exclude=./logs --exclude=./cache.bin --exclude=./blocklists .
  tar -tzf "$TMP/technitium.tar.gz" | grep -qx './dns.config' \
    || die "technitium: archive has no dns.config"
  upload technitium "$TMP/technitium.tar.gz"
}

backup() {
  in_backup=1
  umask 077
  mkdir -p "$TMP"
  trap 'rm -rf "$TMP"' EXIT
  # Read the storage credentials and the public key once, for every target.
  storage
  [ -n "${AGE_RECIPIENT:-}" ] || AGE_RECIPIENT=$(op_read "op://$VAULT/$AGE_ITEM/public_key")
  case "$AGE_RECIPIENT" in age1?*) export AGE_RECIPIENT ;; *) die "AGE_RECIPIENT is not an age public key (age1...)" ;; esac
  failed=""
  for t in $TARGETS; do
    # A separate process, not a ( ) subshell: `set -e` is ignored inside
    # anything on the left of `||`, so a failed upload could go on to prune.
    "$0" _one "$t" || failed="$failed $t"
  done
  [ -z "$failed" ] || die "failed:$failed"
  if [ -n "${PUSH_URL:-}" ]; then
    push up OK && log "checked in with Uptime Kuma" \
      || log "WARNING: Uptime Kuma check-in failed (backups themselves are fine)"
  fi
}

restore() {
  t="${1:-}"
  case " $ALL_TARGETS " in *" $t "*) ;; *) die "usage: pi-backup restore <$(echo $ALL_TARGETS | tr ' ' '|')>" ;; esac
  case "$t" in
    pocket-id) live=/pocket-id/data/pocket-id.db ;;
    technitium) live=/etc/dns/dns.config ;;
  esac
  if [ -s "$live" ] && [ "${FORCE:-}" != 1 ]; then
    die "$live already exists. Stop $t and run again with FORCE=1."
  fi
  storage
  if [ -n "${BACKUP_ID:-}" ]; then
    name="${BACKUP_ID##*/}"  # also accept <target>/<name>, as `list` prints it
  else
    all=$(backups "$t")
    name=$(printf '%s\n' "$all" | head -n 1)
  fi
  [ -n "$name" ] || die "no $t backups in $(bucket "$t")"
  umask 077
  mkdir -p "$TMP"
  trap 'rm -rf "$TMP"' EXIT
  if [ -n "${AGE_IDENTITY:-}" ]; then
    printf '%s\n' "$AGE_IDENTITY" >"$TMP/identity"
  else
    op_read "op://$VAULT/$AGE_ITEM/private_key" >"$TMP/identity"
  fi
  rclone copyto "$(bucket "$t")/$name" "$TMP/restore.age"
  f="$TMP/restore"
  age -d -i "$TMP/identity" -o "$f" "$TMP/restore.age"
  log "restoring $t/$name"
  case "$t" in
    pocket-id)
      pocket_id_env
      pocket-id import --path "$f" --yes
      ;;
    technitium)
      tar -C /etc/dns -xzpf "$f"
      ;;
  esac
  log "restore done -- start $t now"
}

list() {
  storage
  for t in $TARGETS; do
    all=$(backups -s "$t")
    [ -z "$all" ] || printf '%s\n' "$all" | sed "s#^#$t/#"
  done
}

serve() {
  schedule="${BACKUP_SCHEDULE:-25 7 * * *}"
  # busybox crond doesn't pass the container's environment to jobs.
  (umask 077; export -p >/run/pi-backup.env)
  echo "$schedule . /run/pi-backup.env; /usr/local/bin/pi-backup backup >/proc/1/fd/1 2>&1" \
    >/etc/crontabs/root
  log "backing up [$TARGETS] on '$schedule' (UTC) to R2, keeping the newest $KEEP of each"
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
