# pi-backup

Nightly backups of a homelab's app state to 1Password, with a one-command
restore per app. Written for a Raspberry Pi running these apps with
Podman/Docker Compose; works on any host.

| Target | What's backed up | How |
|---|---|---|
| `pocket-id` | [Pocket ID](https://github.com/pocket-id/pocket-id): users, passkeys, groups, OIDC clients, signing keys | Pocket ID's own `pocket-id export`, using the binary from the same Pocket ID version |
| `arcane` | [Arcane](https://github.com/getarcaneapp/arcane)'s SQLite database: environments, users, API keys | SQLite's online backup, then an integrity check |
| `technitium` | [Technitium DNS](https://technitium.com/dns/)'s config: settings, users/SSO, zones | Archive of `/etc/dns` without stats, logs, cache and downloadable block lists |

Each night it backs up every target and uploads each as a 1Password document
titled `<target>-backup <date>`, tagged `<target>-backup`. It keeps the newest
`KEEP` of each, deleting older ones only after a successful upload. When every
target succeeds it calls `PUSH_URL` (e.g. an Uptime Kuma push monitor), so a
missed night can alert you.

## Image

`ghcr.io/mfmseth/pi-backup:<pocket-id version>`, for amd64 and arm64.
**Use the tag that equals your Pocket ID version** (e.g. `2.16.0` for
`pocket-id:v2.16.0`).

## Mounts

| Path in the container | Mount |
|---|---|
| `/pocket-id/data` | Pocket ID's data volume |
| `/arcane` | Arcane's data volume |
| `/etc/dns` | Technitium's config directory |

## Settings

| Variable | Default | |
|---|---|---|
| `OP_SERVICE_ACCOUNT_TOKEN` | (required) | 1Password service-account token with read/write on the vault. Connect tokens can't upload documents. |
| `OP_VAULT` | `homelab` | Vault for the backups. |
| `TARGETS` | `pocket-id arcane technitium` | Which targets to back up. |
| `KEEP` | `3` | How many backups of each target to keep. |
| `BACKUP_SCHEDULE` | `25 7 * * *` | Cron schedule, UTC. |
| `PUSH_URL` | (none) | URL to call after a night where every target succeeded. |
| `ENCRYPTION_KEY` | read from `op://$OP_VAULT/pocket-id/encryption_key` | Pocket ID's `ENCRYPTION_KEY`, needed for its export and import. |

See [`compose.example.yml`](compose.example.yml).

## Commands

```sh
docker exec pi-backup pi-backup backup   # back up every target now
docker exec pi-backup pi-backup list     # backups, newest first
```

## Restore

With the app **stopped** (or not started yet on a new machine):

```sh
docker compose run --rm pi-backup restore pocket-id   # or arcane / technitium
```

then start the app. Pocket ID comes back with the same users, passkeys and
OIDC clients (start it with the same `ENCRYPTION_KEY`), so every app's
sign-in keeps working.

- It restores the newest backup. Pick another with `-e BACKUP_ID=<id>` (from
  `list`).
- It refuses to overwrite existing data. To replace it, stop the app and add
  `-e FORCE=1`.

## Safety

- Backups hold sensitive data: Pocket ID's encrypted signing keys, users'
  emails, API keys. 1Password encrypts them; don't copy them anywhere public.
- Nothing secret is in this repo or the image. All secrets come from the
  environment or 1Password at runtime.
