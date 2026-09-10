# Migration Report: python-flask

## Summary

- Status: verified — both images build, all three comparisons performed, 5/5 tests passed
- Original base: python:3.12-slim
- Migrated base: cgr.dev/chainguard/wolfi-base:latest plus the versioned python-3.12 apk package
- Build invocation: docker build -t <tag> . (fixture directory as context; no -f, no build args, no --platform, no --target)

## Layer-by-Layer Changes

### FROM python:3.12-slim
- Migrated: FROM cgr.dev/chainguard/wolfi-base:latest + RUN apk add --no-cache python-3.12 py3.12-pip
- The public catalog serves the purpose-built python image only at latest,
  which carried Python 3.14.7 at migration time — a different major.minor
  than the pinned 3.12. Run unattended, the skill takes wolfi-base plus the
  versioned apk package so the runtime version does not drift without
  consent. Wolfi's python-3.12 carried 3.12.14, the same version the
  original base resolved to.
- Build fix applied: a first draft also installed python-as-3.12 for the
  bare `python` command, but apk failed the install because python-3.12
  already owns /usr/bin/python; the package was removed from the line.

### RUN pip install --no-cache-dir -r requirements.txt
- Unchanged. py3.12-pip provides pip; wolfi-base runs as root, so no USER
  wrap is needed.

### WORKDIR /app, COPY requirements.txt ., COPY app.py ., EXPOSE 8080, CMD ["python", "app.py"]
- Unchanged. python-3.12 provides /usr/bin/python, so the CMD resolves;
  wolfi-base has no ENTRYPOINT, so the exec-form CMD runs as written.

## Package Changes

- Added (wolfi): python-3.12, py3.12-pip
- requirements.txt unchanged: flask==3.0.3 installs from PyPI. For hardened
  language dependencies, see Chainguard Libraries (libraries.cgr.dev).

## Config Differences

- User: unset -> "0" (both run as root; the original base sets no USER and
  wolfi-base declares root explicitly)
- Env: lost GPG_KEY, PYTHON_SHA256, PYTHON_VERSION, LANG=C.UTF-8 (upstream
  base-image internals the app does not read); gained SSL_CERT_FILE
  (wolfi-base's certificate bundle pointer); PATH orders the same standard
  directories differently — python resolves in both
- WorkingDir, Entrypoint, Cmd, ExposedPorts, Volumes, Shell, Healthcheck:
  unchanged
- Labels: the original Dockerfile sets none

## Functional Tests

- [PASS] python --version: 3.12.14 in both images (no drift)
- [PASS] python3 --version: 3.12.14 in the migrated image
- [PASS] python -c "import flask": flask 3.0.3
- [PASS] file exists: /app/app.py
- [PASS] app startup; HTTP GET / on 127.0.0.1 (ephemeral port) returned
  body "ok" from both images

## Warnings

- The original was not digest-pinned, so the migration is not digest-pinned.
- Wolfi is a rolling distribution: python-3.12 tracks the latest 3.12.x
  patch release rather than a frozen build.

## What Was Not Tested

- Nothing beyond the Flask development server; the fixture has no other
  entrypoints.
