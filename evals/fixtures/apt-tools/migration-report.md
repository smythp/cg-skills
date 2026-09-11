# Migration Report: apt-tools

## Summary

- Status: verified — both images build, all three comparisons performed, 4/4 tests passed
- Original base: ubuntu:22.04
- Migrated base: cgr.dev/chainguard/wolfi-base:latest
- Build invocation: docker build -t <tag> . (fixture directory as context; no -f, no build args, no --platform, no --target)

## Layer-by-Layer Changes

### FROM ubuntu:22.04
- Migrated: FROM cgr.dev/chainguard/wolfi-base:latest
- A generic OS base that exists to host packages maps to wolfi-base on the
  public catalog; no purpose-built image applies.

### RUN apt-get update && apt-get install -y --no-install-recommends curl jq ca-certificates && rm -rf /var/lib/apt/lists/*
- Migrated: RUN apk add --no-cache curl jq
- apt-get translated to apk; apt-get update, --no-install-recommends, and
  the list cleanup are apt boilerplate with no apk counterpart under
  --no-cache; ca-certificates dropped because the certificate bundle ships
  in every Chainguard image — verified with an HTTPS request from the
  migrated image (TLS handshake succeeds with no extra package).

### CMD ["sh", "-c", "curl --version && jq --version"]
- Unchanged. wolfi-base provides sh via BusyBox and has no ENTRYPOINT.

## Package Changes

- Added (wolfi): curl, jq
- Dropped: ca-certificates (preinstalled as ca-certificates-bundle)
- Version movement from the base swap: curl 7.81.0 -> 8.22.0, jq 1.6 ->
  1.8.2. Ubuntu 22.04 freezes package versions; Wolfi rolls forward.

## Config Differences

- User: unset -> "0" (both run as root)
- Env: gained SSL_CERT_FILE (wolfi-base's certificate bundle pointer); PATH
  unchanged in content
- WorkingDir, Entrypoint, Cmd, ExposedPorts, Volumes, Shell, Healthcheck:
  unchanged
- Labels: the original Dockerfile sets none

## Functional Tests

- [PASS] image CMD runs to completion in both images (curl --version &&
  jq --version, exit 0)
- [PASS] curl --version: 8.22.0 with https in the protocol list
- [PASS] jq --version: 1.8.2
- [PASS] HTTPS request from the migrated image succeeds without
  ca-certificates installed (the bundled certificates are used)

## Warnings

- curl and jq are newer in the migrated image (see Package Changes); any
  consumer pinned to Ubuntu 22.04's curl 7.x/jq 1.6 behavior should review.
- The original was not digest-pinned, so the migration is not digest-pinned.
- Resolved digests:
  cgr.dev/chainguard/wolfi-base:latest@sha256:65e1acb87a2bf356b92c5f70f3980f03b4bb51dfd483c834e01557525f15c1d9
  (not pinned: original unpinned, unattended run).

## What Was Not Tested

- No application beyond the two CLI tools; the fixture has no server or
  exposed port, so no startup probe applies.
