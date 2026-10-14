# pi-backup

Nightly encrypted backups of a homelab's app state to Cloudflare R2 (or any
S3-compatible storage), with a one-command restore per app. Written for a
Raspberry Pi running these apps with Podman/Docker Compose; works on any host.

| Target | What's backed up | How |
|---|---|---|
| `pocket-id` | [Pocket ID](https://github.com/pocket-id/pocket-id): users, passkeys, groups, OIDC clients, signing keys | Pocket ID's own `pocket-id export`, using the binary from the same Pocket ID version |
| `arcane` | [Arcane](https://github.com/getarcaneapp/arcane)'s SQLite database: environments, users, API keys | SQLite's online backup, then an integrity check |
| `technitium` | [Technitium DNS](https://technitium.com/dns/)'s config: settings, users/SSO, zones | Archive of `/etc/dns` without stats, logs, cache and downloadable block lists |

Each night it backs up every target, encrypts each backup with
[age](https://age-encryption.org) to your public key, and uploads it with
[rclone](https://rclone.org) as `<bucket>/<target>/<target>-<date>_<time>.<ext>.age`.
It keeps the newest `KEEP` of each target, deleting older ones only after a
successful upload. When every target succeeds it calls `PUSH_URL` (e.g. an
Uptime Kuma push monitor), so a missed night can alert you.

Backing up needs only the age **public** key. The **private** key is needed
only to restore, so keep it somewhere that survives losing the host (it's in
1Password here). Without it the backups can't be read.

## Image

`ghcr.io/mfmseth/pi-backup:<pocket-id version>`, for amd64 and arm64.
**Use the tag that equals your Pocket ID version** (e.g. `2.18.0` for
`pocket-id:v2.18.0`): Pocket ID refuses to export a database that a newer
version has migrated.

## Mounts

| Path in the container | Mount |
|---|---|
| `/pocket-id/data` | Pocket ID's data volume |
| `/arcane` | Arcane's data volume |
| `/etc/dns` | Technitium's config directory |

## Settings

Everything secret can come from the environment or, when it isn't set there,
from 1Password with a service-account token.

| Variable | Default | |
|---|---|---|
| `OP_SERVICE_ACCOUNT_TOKEN` | (none) | 1Password service-account token with read access to the vault. Not needed if every secret below is set directly. |
| `OP_VAULT` | `homelab` | Vault the items below are read from. |
| `R2_ITEM` | `cloudflare-r2-pi-backup` | 1Password item with the fields `access_key_id`, `secret_access_key`, `account_id` and `bucket`. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET` | from `R2_ITEM` | Storage credentials and bucket. Use an R2 API token with Object Read & Write on this bucket only. |
| `S3_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` | Set it (and `S3_PROVIDER`, rclone's name for it) for other S3-compatible storage. |
| `AGE_ITEM` | `pi-backup-age` | 1Password item with the fields `public_key` and `private_key` (from `age-keygen`). |
| `AGE_RECIPIENT` | `public_key` from `AGE_ITEM` | age public key (`age1...`) the backups are encrypted to. |
| `AGE_IDENTITY` | `private_key` from `AGE_ITEM` | age private key (`AGE-SECRET-KEY-1...`), read only by `restore`. |
| `TARGETS` | `pocket-id arcane technitium` | Which targets to back up. |
| `KEEP` | `14` | How many backups of each target to keep. |
| `BACKUP_SCHEDULE` | `25 7 * * *` | Cron schedule, UTC. |
| `PUSH_URL` | (none) | URL to call after a night where every target succeeded. |
| `ENCRYPTION_KEY` | read from `op://$OP_VAULT/pocket-id/encryption_key` | Pocket ID's `ENCRYPTION_KEY`, needed for its export and import. |

See [`compose.example.yml`](compose.example.yml).

## Commands

```sh
docker exec pi-backup pi-backup backup   # back up every target now
docker exec pi-backup pi-backup list     # backups and their sizes, newest first
```

## Restore

With the app **stopped** (or not started yet on a new machine):

```sh
docker compose run --rm pi-backup restore pocket-id   # or arcane / technitium
```

then start the app. Pocket ID comes back with the same users, passkeys and
OIDC clients (start it with the same `ENCRYPTION_KEY`), so every app's
sign-in keeps working.

- It restores the newest backup. Pick another with `-e BACKUP_ID=<name>`, as
  printed by `list` (e.g. `arcane/arcane-2026-10-14_071500.db.gz.age`).
- It refuses to overwrite existing data. To replace it, stop the app and add
  `-e FORCE=1`.

To decrypt a backup by hand: `rclone copy` it from the bucket, then
`age -d -i key.txt -o out <file>.age`.

## Safety

- Backups hold sensitive data: Pocket ID's encrypted signing keys, users'
  emails, API keys. They're encrypted with age before they leave the host, so
  the storage provider only ever sees ciphertext.
- Nothing secret is in this repo or the image. All secrets come from the
  environment or 1Password at runtime.
