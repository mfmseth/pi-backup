# pocket-id-backup

Nightly backups of [Pocket ID](https://github.com/pocket-id/pocket-id) to
1Password, and a one-command restore.

The image is Pocket ID's own image plus the 1Password CLI, so the export and
import always match your Pocket ID version. Each run:

1. exports Pocket ID (users, passkeys, groups, OIDC clients, signing keys)
   with `pocket-id export`;
2. checks the export really contains users (it refuses to upload an empty one);
3. uploads it to 1Password as a document titled `pocket-id-backup <date>`,
   tagged `pocket-id-backup`;
4. deletes all but the newest `KEEP` backups (only after a successful upload);
5. optionally calls a check-in URL, e.g. an Uptime Kuma push monitor.

## Image

`ghcr.io/mfmseth/pocket-id-backup:<pocket-id version>`, for amd64 and arm64.
**Use the tag that equals your Pocket ID version** (e.g. `2.16.0` for
`pocket-id:v2.16.0`).

## Settings

| Variable | Default | |
|---|---|---|
| `OP_SERVICE_ACCOUNT_TOKEN` | (required) | 1Password service-account token with read/write on the vault. Connect tokens can't upload documents. |
| `OP_VAULT` | `homelab` | Vault for the backups. |
| `ENCRYPTION_KEY` | read from `op://$OP_VAULT/pocket-id/encryption_key` | Pocket ID's `ENCRYPTION_KEY`. |
| `KEEP` | `3` | How many backups to keep. |
| `BACKUP_SCHEDULE` | `15 7 * * *` | Cron schedule, UTC. |
| `PUSH_URL` | (none) | URL to call after each successful backup. |
| `BACKUP_TAG` | `pocket-id-backup` | 1Password tag that marks the backups. |

Mount Pocket ID's data volume at `/app/data`. See
[`compose.example.yml`](compose.example.yml).

## Commands

```sh
docker exec pocket-id-backup pocket-id-backup backup   # back up now
docker exec pocket-id-backup pocket-id-backup list     # backups, newest first
```

## Restore

On a new machine, with Pocket ID **not running**:

```sh
docker compose run --rm pocket-id-backup restore
docker compose up -d pocket-id
```

- It restores the newest backup. Pick another with `-e BACKUP_ID=<id>` (from
  `list`).
- It refuses to overwrite an existing database. To replace one, stop Pocket ID
  and add `-e FORCE=1`.
- Start Pocket ID with the same `ENCRYPTION_KEY`. Users, passkeys and every
  app's sign-in work as before.

## Safety

- The export contains Pocket ID's (encrypted) signing keys, your users'
  emails and sign-in logs. Keep backups somewhere private; 1Password encrypts
  them.
- Nothing secret is in this repo or the image. All secrets come from the
  environment or 1Password at runtime.
