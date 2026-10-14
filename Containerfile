# pi-backup: Alpine + the 1Password CLI + the pocket-id binary, with
# age to encrypt and rclone to upload to Cloudflare R2.
# The published image is tagged with the Pocket ID version in the pocket-id
# FROM line below (e.g. ghcr.io/mfmseth/pi-backup:2.18.0): run the tag that
# equals your Pocket ID version, so export/import match its database.
FROM docker.io/1password/op:2.39.0 AS op
FROM ghcr.io/pocket-id/pocket-id:v2.18.0 AS pocket-id
FROM docker.io/rclone/rclone:1.75.2 AS rclone

# age has no official image: build it from source (checked against the Go
# checksum database), cross-compiled on the build machine for each platform.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27.2-alpine3.24 AS age
ARG TARGETOS TARGETARCH
# renovate: datasource=go depName=filippo.io/age
ARG AGE_VERSION=v1.3.2
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go install -trimpath -ldflags="-s -w" filippo.io/age/cmd/age@$AGE_VERSION filippo.io/age/cmd/age-keygen@$AGE_VERSION \
    && mkdir /out && find /go/bin -type f -exec cp {} /out/ \;

FROM docker.io/library/alpine:3.24
LABEL org.opencontainers.image.source="https://github.com/mfmseth/pi-backup"
LABEL org.opencontainers.image.description="Nightly encrypted backups of Pocket ID and Technitium to Cloudflare R2, with one-command restores"
RUN apk add --no-cache jq tar
COPY --from=op /usr/local/bin/op /usr/local/bin/op
COPY --from=pocket-id /app/pocket-id /usr/local/bin/pocket-id
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=age /out/ /usr/local/bin/
COPY pi-backup.sh /usr/local/bin/pi-backup
RUN chmod 755 /usr/local/bin/pi-backup
ENTRYPOINT ["/usr/local/bin/pi-backup"]
CMD ["serve"]
