# Migration Report: django

## Summary

- Status: verified — both images build, all three comparisons performed, 6/6 tests passed
- Original base: python:3.12-slim-bookworm
- Migrated base: cgr.dev/chainguard/wolfi-base:latest plus the versioned python-3.12 apk package
- Build invocation: docker build -t <tag> . (fixture directory as context; no -f, no build args, no --platform, no --target; ARG REQ_FILE keeps its default requirements/prod.txt)

## Layer-by-Layer Changes

### FROM python:3.12-slim-bookworm
- Migrated: FROM cgr.dev/chainguard/wolfi-base:latest, with python-3.12 and
  py3.12-pip added to the first package layer.
- The public catalog serves the purpose-built python image only at latest,
  which carried Python 3.14.7 at migration time — a different major.minor
  than the pinned 3.12. Run unattended, the skill takes wolfi-base plus the
  versioned apk package so the runtime version does not drift without
  consent. Wolfi's python-3.12 carried 3.12.14, the same version the
  original base resolved to.

### RUN apt-get install gettext git libpq5 make rsync
- Migrated: RUN apk add --no-cache python-3.12 py3.12-pip gettext git libpq-17 make rsync
- gettext, git, make, rsync keep their names. libpq5 has no Wolfi package of
  that name; the shared-library lookup (so:libpq.so.5) resolves it to the
  versioned libpq-<N> series, and libpq-17 was chosen to match the
  postgresql-17-dev build package below. apt-get update and the list cleanup
  are apt boilerplate dropped under apk --no-cache.

### RUN apt-get install g++ gcc libc6-dev libpq-dev zlib1g-dev && python3 -m pip install ... && apt-get purge ...
- Migrated: RUN apk add --no-cache gcc glibc-dev postgresql-17-dev python-3.12-dev zlib-dev && python3 -m pip install --no-cache-dir -r ${REQ_FILE} && apk del ...
- g++ and gcc collapse to Wolfi's gcc, which ships g++. libc6-dev ->
  glibc-dev. libpq-dev does not exist in Wolfi; postgresql-17-dev provides
  pg_config (PostgreSQL 17.10, on PATH at /usr/bin/pg_config) and the libpq
  headers psycopg[c] compiles against. zlib1g-dev -> zlib-dev.
- Added: python-3.12-dev. Debian's python image bundles the Python headers;
  Wolfi splits them into a -dev package, and psycopg-c does not compile
  without them.
- The pip line is unchanged (python-3.12 provides python3; py3.12-pip
  provides the pip module). apt-get purge --auto-remove translates to apk
  del of the same set, which also removes orphaned dependencies; verified
  gcc is absent from the final image.

### WORKDIR, ENV PYTHONDONTWRITEBYTECODE / PYTHONUNBUFFERED, ARG REQ_FILE, COPY ./requirements, COPY . .
- Unchanged, including the original's legacy space-form ENV syntax (BuildKit
  warns on it identically for both files).

### CMD ["python3"]
- Added. The original sets no CMD or ENTRYPOINT and inherits CMD ["python3"]
  from python:3.12-slim-bookworm; wolfi-base's default is a login shell.
  Replicating the inherited default keeps docker run behavior identical —
  the config comparison shows Cmd equal after the addition. The upstream
  comment about ENTRYPOINT living in docker-compose is preserved.

## Package Changes

- Added (wolfi): python-3.12, py3.12-pip, gettext, git, libpq-17, make,
  rsync; build-only (removed in the same layer): gcc, glibc-dev,
  postgresql-17-dev, python-3.12-dev, zlib-dev
- Renamed: libpq5 -> libpq-17, libc6-dev -> glibc-dev, libpq-dev ->
  postgresql-17-dev, zlib1g-dev -> zlib-dev, g++/gcc -> gcc
- requirements/ unchanged: all 47 distributions install from PyPI (and
  django-push from its commit-pinned git URL, which is why git stays in the
  runtime layer). psycopg-c 3.2.5 compiles from source in both images. For
  hardened language dependencies, see Chainguard Libraries
  (libraries.cgr.dev).

## Config Differences

- User: unset -> "0" (both run as root)
- Env: lost GPG_KEY, PYTHON_SHA256, PYTHON_VERSION, LANG=C.UTF-8 (upstream
  base-image internals); gained SSL_CERT_FILE (wolfi-base's certificate
  bundle pointer); PYTHONDONTWRITEBYTECODE and PYTHONUNBUFFERED carry over
  unchanged
- WorkingDir, Entrypoint, Cmd, ExposedPorts, Volumes, Shell, Healthcheck:
  unchanged (Cmd matches because the migration replicates the inherited
  ["python3"])
- Labels: the original Dockerfile sets none

## Functional Tests

- [PASS] python -c "import django, psycopg, PIL, sass": django 5.1.7 in
  both images
- [PASS] python3 --version: 3.12.14 (no drift)
- [PASS] git --version, msgfmt --version, rsync --version, make --version
  in the migrated image
- [PASS] pg_config present during the build layer (PostgreSQL 17.10);
  psycopg-c compiled and imports
- [PASS] gcc absent from the final image (apk del removed the build set)
- [PASS] file exists: /usr/src/app/requirements/prod.txt (COPY . . landed)

## Warnings

- libpq moved from Debian bookworm's PostgreSQL-15 build to Wolfi's
  libpq-17. The libpq wire protocol is compatible across these majors and
  psycopg imports cleanly, but a deployment pinned to a PostgreSQL 15 server
  feature set should review.
- The original was not digest-pinned, so the migration is not digest-pinned.
- Wolfi is a rolling distribution: python-3.12 tracks the latest 3.12.x
  patch release rather than a frozen build.
- Resolved digests:
  cgr.dev/chainguard/wolfi-base:latest@sha256:65e1acb87a2bf356b92c5f70f3980f03b4bb51dfd483c834e01557525f15c1d9
  (not pinned: original unpinned, unattended run).

## What Was Not Tested

- No application startup: the image deliberately defines no entrypoint (the
  upstream project starts it via docker-compose), and no port is exposed, so
  no HTTP probe applies. Database connectivity (psycopg against a live
  PostgreSQL) was not tested; only the import path was.
