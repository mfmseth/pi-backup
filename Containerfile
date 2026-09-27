# pi-backup: Alpine + sqlite + the 1Password CLI + the pocket-id binary.
# The published image is tagged with the Pocket ID version in the pocket-id
# FROM line below (e.g. ghcr.io/mfmseth/pi-backup:2.16.0): run the tag that
# equals your Pocket ID version, so export/import match its database.
FROM docker.io/1password/op:2.39.0 AS op
FROM ghcr.io/pocket-id/pocket-id:v2.16.0 AS pocket-id

FROM docker.io/library/alpine:3.24
LABEL org.opencontainers.image.source="https://github.com/mfmseth/pi-backup"
LABEL org.opencontainers.image.description="Nightly backups of Pocket ID, Arcane and Technitium to 1Password, with one-command restores"
RUN apk add --no-cache jq sqlite tar
COPY --from=op /usr/local/bin/op /usr/local/bin/op
COPY --from=pocket-id /app/pocket-id /usr/local/bin/pocket-id
COPY pi-backup.sh /usr/local/bin/pi-backup
RUN chmod 755 /usr/local/bin/pi-backup
ENTRYPOINT ["/usr/local/bin/pi-backup"]
CMD ["serve"]
