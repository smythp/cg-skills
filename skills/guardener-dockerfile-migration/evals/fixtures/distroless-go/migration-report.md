# Migration Report: distroless-go

## Summary

- Status: verified — both images build, all three comparisons performed, 3/3 tests passed
- Original bases: golang:1.22 (build), gcr.io/distroless/static-debian12 (runtime)
- Migrated bases: cgr.dev/chainguard/wolfi-base:latest plus the versioned go-1.22 apk package (build), cgr.dev/chainguard/static:latest (runtime)
- Build invocation: docker build -t <tag> . (fixture directory as context; no -f, no build args, no --platform, no --target)

## Layer-by-Layer Changes

### FROM golang:1.22 as build
- Migrated: FROM cgr.dev/chainguard/wolfi-base:latest AS build + RUN apk add --no-cache go-1.22
- The public catalog serves the purpose-built go image only at latest,
  which carried go 1.27.1 at migration time — a different major.minor than
  the pinned 1.22. Run unattended, the skill takes wolfi-base plus the
  versioned apk package so the toolchain version does not drift without
  consent. Both images resolved to go 1.22.12.

### RUN go mod download / go vet -v / go test -v / CGO_ENABLED=0 go build -o /go/bin/app
- Unchanged. go vet and go test pass in the migrated stage (the module has
  no test files, which go test reports and exits 0). With no C compiler in
  the stage, go disables cgo on its own for vet and test; the final build
  sets CGO_ENABLED=0 explicitly, as the original did.

### FROM gcr.io/distroless/static-debian12
- Migrated: FROM cgr.dev/chainguard/static:latest
- A distroless static-binary runtime maps to the static image, which holds
  certificates and a nonroot user and nothing else.

### COPY --from=build /go/bin/app /, CMD ["/app"]
- Unchanged. The binary is root-owned mode 0755, which the static image's
  65532 user can read and execute; no --chown is needed.

## Package Changes

- Added (wolfi, build stage only): go-1.22
- The runtime stage installs nothing in either version.

## Config Differences

- User: "0" -> "65532" (intentional: distroless/static-debian12's default
  tag runs as root, Chainguard's static runs as nonroot; the binary needs no
  privileges — verified by running it)
- WorkingDir: "/" -> unset (an unset working directory resolves to /; no
  behavioral difference)
- Env: identical (PATH content matches; both set SSL_CERT_FILE)
- Entrypoint, Cmd, ExposedPorts, Volumes, Shell, Healthcheck: unchanged
- Labels: the original Dockerfile sets none

## Functional Tests

- [PASS] docker run of both images prints "Hello, world!" and exits 0
- [PASS] go vet and go test pass in the migrated build stage
- [PASS] file exists: /app in the migrated runtime image (static Go binary,
  ~1.9 MB)

## Warnings

- The original was not digest-pinned, so the migration is not digest-pinned.
- Wolfi is a rolling distribution: go-1.22 tracks the latest 1.22.x patch
  release rather than a frozen build.
- Resolved digests:
  cgr.dev/chainguard/wolfi-base:latest@sha256:65e1acb87a2bf356b92c5f70f3980f03b4bb51dfd483c834e01557525f15c1d9
  (not pinned: original unpinned, unattended run);
  cgr.dev/chainguard/static:latest@sha256:207a5673ab31ed83332e54ae33d0f1de4adb5984bd93b8309789889e7bf30ba6
  (not pinned: original unpinned, unattended run).

## What Was Not Tested

- Nothing else ships in the runtime image; the fixture has no server or
  exposed port, so no startup probe applies.
