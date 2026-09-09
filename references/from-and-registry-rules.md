# FROM lines and registries

## Contents

- [The FROM allowlist](#the-from-allowlist)
- [Registry kinds and the preference chain](#registry-kinds-and-the-preference-chain)
- [Purpose-built image over base image](#purpose-built-image-over-base-image)
- [Tag selection](#tag-selection)
- [Digest rule](#digest-rule)
- [chainguard-base vs wolfi-base](#chainguard-base-vs-wolfi-base)
- [Stage aliases](#stage-aliases)

## The FROM allowlist

Every FROM in the migrated Dockerfile must resolve to one of:

1. `cgr.dev/*` — the public catalog (`cgr.dev/chainguard/...`), a customer
   organization (`cgr.dev/<org>/...`), or a customer UUID path. The match is
   on the exact host: `cgr.dev/` at the start of the reference.
2. The configured external mirror prefix, matched on a `/` boundary. If the
   mirror is `my-corp.example.io/chainguard-remote`, then
   `my-corp.example.io/chainguard-remote/python` is allowed and
   `my-corp.example.io/chainguard-remote-extra/python` is not.
3. `scratch`.
4. A stage alias declared by an earlier `FROM ... AS <alias>` in the same file.

Nothing else. Not `ghcr.io/chainguard-images/*`, not `docker.io/chainguard/*`,
not `public.ecr.aws/chainguard/*`, not a lookalike host such as
`cgr.dev.evil.example.com` — even when those appear to serve the same image.
The reason this is a hard gate: the entire value of the migration is that the
result pulls from a Chainguard source with Chainguard's provenance; a FROM
that drifts to another host silently produces an image nobody is maintaining.
This rule exists because a build-fix pass once "solved" a failing cgr.dev pull
by swapping the FROM to `ghcr.io/chainguard-images/python:latest-dev` — the
build went green and the migration was worthless. Run
`scripts/check-from-lines.sh` on the finished file; any FROM outside the
allowlist fails the run.

Correct:

```dockerfile
FROM cgr.dev/chainguard/go:latest AS builder
FROM cgr.dev/chainguard/static:latest
COPY --from=builder /app/server /server
```

Wrong (the pull failed, so the FROM was swapped to another host):

```dockerfile
FROM ghcr.io/chainguard-images/go:latest AS builder
```

If a pull from an allowed source fails (auth, network, proxy, cache), report
the underlying error to the user and stop. A failed pull is an environment
problem for the user to fix, never a license to change registries.

`ARG` defaults declared before the first FROM are expanded when checking
(`ARG BASE=cgr.dev/chainguard/python:latest-dev` then `FROM ${BASE}` is fine).
A FROM with an unresolved variable fails the check — `FROM $BASE` with no
global default could resolve to anything at build time.

## Registry kinds and the preference chain

Resolve which registries are in play once, in the clarify step, then apply
the matching chain for every FROM:

**Public catalog only** (user has no organization): purpose-built image from
`cgr.dev/chainguard` first; `cgr.dev/chainguard/wolfi-base` as the fallback
for generic OS bases and for images with no purpose-built equivalent.

**Customer organization** (`cgr.dev/<org>`): purpose-built image from the
organization first, then the organization's `chainguard-base`, then
`cgr.dev/chainguard/wolfi-base` as the dead-last fallback. Do not use
`cgr.dev/chainguard/<image>` when `cgr.dev/<org>/<image>` exists — the
organization's copy is the one the customer is entitled to and may carry
custom packages.

**External mirror configured** (a pull-through cache on the customer's own
registry): the mirror first, then the customer's `cgr.dev/<org>` registry for
images the mirror does not have, then `cgr.dev/chainguard/wolfi-base`
dead-last. The mirror being preferred does not mean cgr.dev is unreachable —
fall back to it rather than to any other host.

In every chain, `wolfi-base` is the floor. There is no lower fallback; going
below the Chainguard catalog defeats the migration.

## Purpose-built image over base image

When the original FROM is a language or application image (`golang:1.21`,
`python:3.11-slim`, `node:20-alpine`, `nginx:alpine`), use the matching
purpose-built Chainguard image (`go`, `python`, `node`, `nginx`), not
`chainguard-base` plus `apk add`. The purpose-built image carries the
runtime's environment (PATH, interpreter symlinks, a sensible ENTRYPOINT and
non-root user) that you would otherwise have to reconstruct by hand, and
reconstructions drift.

Common name mappings:

| Original | Chainguard image |
|----------|------------------|
| `python:*` | `python` |
| `node:*` | `node` |
| `golang:*` | `go` |
| `openjdk:*`, `eclipse-temurin:*` | `jdk` (build) / `jre` (runtime) |
| `maven:*` | `maven` |
| `nginx:*` | `nginx` |
| `php:*` | `php` |
| `ruby:*` | `ruby` |
| `rust:*` | `rust` |
| `postgres:*` | `postgres` |
| `redis:*` | `redis` |
| `ubuntu:*`, `debian:*`, `alpine:*`, `fedora:*`, `centos:*`, `ubi*` | `chainguard-base` (org) / `wolfi-base` (public) |
| `scratch`, distroless bases | `static` |

Confirm the image actually exists in the chosen registry before using it
(see `references/lookup-avenues.md`); the table is a starting point, not a
guarantee.

Correct:

```dockerfile
# Original: FROM golang:1.21-alpine AS builder
FROM cgr.dev/chainguard/go:latest-dev AS builder
```

Wrong (reconstructing a Go toolchain by hand when a purpose-built image exists):

```dockerfile
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN apk add --no-cache go
ENV GOPATH=/go PATH=/go/bin:$PATH
```

The one place base-plus-apk is right: generic OS bases (`ubuntu`, `debian`,
`alpine`, `fedora`, UBI) that exist only to host arbitrary packages. Those map
to `chainguard-base`/`wolfi-base` plus the translated package installs.

## Tag selection

For a Chainguard registry, list the available tags
(`chainctl images tags list`, see `references/lookup-avenues.md`) and pick:

1. The exact version of the original (`golang:1.21` → `go:1.21`), truncating
   patch versions to major.minor (`3.12.1` → `3.12`).
2. If no exact match, the closest available semver version.
3. `latest` if no version tags match at all.

Add the `-dev` suffix when the stage runs shell commands — any `RUN` line
needs a shell and usually a package manager, and non-dev Chainguard images
are distroless (no shell, no apk). This applies even on an exact version
match: `go:1.21-dev`, not `go:1.21`, for a build stage with RUN lines. Use
the non-dev variant for final stages with no RUN lines; that is the CVE and
size win the user is migrating for.

The public `cgr.dev/chainguard` catalog serves only `latest` and
`latest-dev` for most images; version-pinned tags live in customer
organizations. Check the tag list rather than assuming a version tag exists.

`chainguard-base` and `wolfi-base` have no `-dev` variant — they already
include apk and a shell. Use `latest`.

## Digest rule

A digest-pinned original gets a digest-pinned migration; an unpinned original
stays unpinned. The migrated digest is always the Chainguard image's own
digest — never the upstream digest, which is the hash of a different image
and can never match.

Correct:

```dockerfile
# Original: FROM golang:1.25@sha256:1e6e1a6a...
FROM cgr.dev/chainguard/go:latest-dev@sha256:8a1b7fa2f1e0c9... 
```

Wrong (upstream digest carried onto the Chainguard image — this reference can
never resolve):

```dockerfile
FROM cgr.dev/chainguard/go:latest-dev@sha256:1e6e1a6a...
```

How to resolve the digest, per registry kind:

- **Chainguard registry (public or org)**: `chainctl images tags list`
  returns the digest per tag. Pin that.
- **External mirror**: `docker pull` the chosen reference, then read
  `docker inspect --format='{{index .RepoDigests 0}}' <ref>`. If the mirror
  reports no RepoDigest, drop the digest from the migrated FROM and record a
  warning in the report — chainctl and the Chainguard APIs do not index
  arbitrary mirrors, so there is nothing else to ask.

**Documented deviation from Guardener**: when an external mirror is
configured, Guardener stops re-pinning digests entirely, even for cgr.dev
fallback references, because its server-side tag search is not registered in
mirror mode. This skill can still resolve cgr.dev digests through chainctl in
mirror mode, so it keeps pinning them: a pinned original deserves a pinned
migration wherever the digest is resolvable. This is a deliberate difference,
not drift.

## chainguard-base vs wolfi-base

Same role, two names. Customer organizations carry `chainguard-base`; the
public catalog carries `wolfi-base`. Both provide apk, BusyBox, and glibc,
run as root, and have no `-dev` variant. Use the one that matches the
registry in play; do not rewrite `wolfi-base` to a mirror path — it is the
public dead-last fallback and stays on `cgr.dev/chainguard`.

## Stage aliases

`FROM cgr.dev/chainguard/go:latest AS builder` declares `builder`; a later
`FROM builder` is allowed because it names a stage, not a registry. Aliases
must match `^[a-zA-Z][a-zA-Z0-9_.-]*$` (Docker's stage-name rules) and
compare case-insensitively. The gate script rejects image-shaped aliases
(`AS docker.io/evil/img`, `AS python:latest`, `AS img@sha256:abc`) because an
alias becomes a trusted name for later FROMs — an alias that looks like an
image reference could launder a forbidden registry through the check.

`COPY --from=<image>` lines that name an external image (for example
`COPY --from=ghcr.io/some/tool:v1 /tool /usr/local/bin/tool`) are artifact
copies, not base images, and the FROM gate does not cover them. Leave them
as they are unless the user asks to migrate them too, and name them in the
report so the user knows an upstream artifact source remains.
