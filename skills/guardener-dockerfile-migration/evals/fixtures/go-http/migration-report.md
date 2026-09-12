# Migration Report: go-http

## Summary

- Status: verified — both images build, all three comparisons performed, 4/4 tests passed
- Original base: golang:1.22
- Migrated base: cgr.dev/chainguard/wolfi-base:latest plus the versioned go-1.22 apk package
- Build invocation: docker build -t <tag> . (fixture directory as context; no -f, no build args, no --platform, no --target)

## Layer-by-Layer Changes

### FROM golang:1.22
- Migrated: FROM cgr.dev/chainguard/wolfi-base:latest + RUN apk add --no-cache go-1.22
- The public catalog serves the purpose-built go image only at latest,
  which carried go 1.27.1 at migration time — a different major.minor than
  the pinned 1.22. Run unattended, the skill takes wolfi-base plus the
  versioned apk package so the runtime version does not drift without
  consent. Both images resolved to go 1.22.12 — no version drift at all.
- The original is a single-stage build whose final image keeps the Go
  toolchain; the migration preserves that structure rather than
  restructuring into multi-stage.

### RUN CGO_ENABLED=0 go build -o /bin/server .
- Unchanged. go-1.22 provides /usr/bin/go; wolfi-base runs as root, so no
  USER wrap is needed.

### WORKDIR /src, COPY go.mod ., COPY main.go ., EXPOSE 8080, CMD ["/bin/server"]
- Unchanged. wolfi-base has no ENTRYPOINT, so the exec-form CMD runs as
  written.

## Package Changes

- Added (wolfi): go-1.22
- No language package manager runs (the module has no dependencies), so no
  Chainguard Libraries pointer applies.

## Config Differences

- User: unset -> "0" (both run as root)
- Env: lost GOLANG_VERSION, GOPATH=/go, GOTOOLCHAIN=local (toolchain
  settings of the upstream base; the binary is built during the image build
  and the runtime CMD does not read them — during the migrated build go
  defaults GOPATH to the building user's home, which only moves the module
  cache); gained SSL_CERT_FILE (wolfi-base's certificate bundle pointer);
  PATH lost /go/bin and /usr/local/go/bin (upstream toolchain locations —
  Wolfi's go lives in /usr/bin, which PATH covers)
- WorkingDir, Entrypoint, Cmd, ExposedPorts, Volumes, Shell, Healthcheck:
  unchanged
- Labels: the original Dockerfile sets none

## Functional Tests

- [PASS] go version: go1.22.12 in both images (no drift)
- [PASS] /bin/server exists and is executable in the migrated image
- [PASS] /bin/server starts under sh in the migrated build stage
- [PASS] app startup; HTTP GET / on 127.0.0.1 (ephemeral port) returned
  body "ok" from both images

## Warnings

- The original was not digest-pinned, so the migration is not digest-pinned.
- Wolfi is a rolling distribution: go-1.22 tracks the latest 1.22.x patch
  release rather than a frozen build.
- Resolved digests:
  cgr.dev/chainguard/wolfi-base:latest@sha256:65e1acb87a2bf356b92c5f70f3980f03b4bb51dfd483c834e01557525f15c1d9
  (not pinned: original unpinned, unattended run).

## What Was Not Tested

- Nothing beyond the HTTP server; the fixture has no other entrypoints.
