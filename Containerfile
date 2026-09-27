# Pocket ID's own image plus the 1Password CLI, so export/import always match
# the Pocket ID version in the FROM line. The published image is tagged with
# that version (e.g. ghcr.io/mfmseth/pocket-id-backup:2.16.0): run the tag
# that equals your Pocket ID version.
FROM docker.io/1password/op:2.39.0 AS op

FROM ghcr.io/pocket-id/pocket-id:v2.16.0
LABEL org.opencontainers.image.source="https://github.com/mfmseth/pocket-id-backup"
LABEL org.opencontainers.image.description="Nightly Pocket ID backups to 1Password, with a one-command restore"
RUN apk add --no-cache jq
COPY --from=op /usr/local/bin/op /usr/local/bin/op
COPY pocket-id-backup.sh /usr/local/bin/pocket-id-backup
RUN chmod 755 /usr/local/bin/pocket-id-backup
ENTRYPOINT ["/usr/local/bin/pocket-id-backup"]
CMD ["serve"]
