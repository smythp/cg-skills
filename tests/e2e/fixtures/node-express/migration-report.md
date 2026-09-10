# Migration Report: node-express

## Summary

- Status: verified — both images build, all three comparisons performed, 5/5 tests passed
- Original base: node:20
- Migrated base: cgr.dev/chainguard/wolfi-base:latest plus the versioned nodejs-20 apk package and npm
- Build invocation: docker build -t <tag> . (fixture directory as context; no -f, no build args, no --platform, no --target)

## Layer-by-Layer Changes

### FROM node:20
- Migrated: FROM cgr.dev/chainguard/wolfi-base:latest + RUN apk add --no-cache nodejs-20 npm
- The public catalog serves the purpose-built node image only at latest,
  which carried Node v26.8.1 at migration time — a different major than the
  pinned 20. Run unattended, the skill takes wolfi-base plus the versioned
  apk package so the runtime version does not drift without consent. Both
  images resolved to Node v20.20.2 — no version drift at all.
- Wolfi does not bundle npm with nodejs-20; npm is a separate package (see
  Warnings for the version-support caveat).

### RUN npm install
- Unchanged. Verified: installs 69 packages, and express resolves to 4.22.2
  (within the package.json range ^4.19.2) and loads under node.

### WORKDIR /app, COPY package.json ., COPY server.js ., EXPOSE 8080, CMD ["node", "server.js"]
- Unchanged. wolfi-base has no ENTRYPOINT, so the exec-form CMD runs as
  written; nodejs-20 provides /usr/bin/node.

## Package Changes

- Added (wolfi): nodejs-20, npm (resolves to npm-12)
- package.json unchanged: express ^4.19.2 installs from the npm registry.
  For hardened language dependencies, see Chainguard Libraries
  (libraries.cgr.dev).

## Config Differences

- User: unset -> "0" (both run as root)
- Entrypoint: ["docker-entrypoint.sh"] -> none. The upstream node image's
  entrypoint script only execs the CMD; with no entrypoint the exec-form
  CMD runs directly, verified by the startup probe.
- Env: lost NODE_VERSION and YARN_VERSION (upstream base markers; yarn was
  not used); gained SSL_CERT_FILE (wolfi-base's certificate bundle pointer);
  PATH unchanged in content
- WorkingDir, Cmd, ExposedPorts, Volumes, Shell, Healthcheck: unchanged
- Labels: the original Dockerfile sets none

## Functional Tests

- [PASS] node --version: v20.20.2 in both images (no drift)
- [PASS] node -e "require('express/package.json').version": 4.22.2
- [PASS] npm install: 69 packages added, exit 0
- [PASS] file exists: /app/server.js
- [PASS] app startup; HTTP GET / on 127.0.0.1 (ephemeral port) returned
  body "ok" from both images

## Warnings

- Wolfi carries no npm release that lists Node 20 as supported: the npm
  package resolves to npm 12, which warns "does not support Node.js
  v20.20.2" on every invocation. The install was verified to work for this
  fixture (see Functional Tests), but a project relying on npm at runtime
  should weigh that unsupported pairing. The original node:20 image bundles
  npm 10, which Wolfi does not package.
- The original was not digest-pinned, so the migration is not digest-pinned.
- Wolfi is a rolling distribution: nodejs-20 tracks the latest 20.x patch
  release rather than a frozen build.

## What Was Not Tested

- npm at container runtime (the app only serves HTTP); yarn (present in the
  original base, unused by the fixture, not installed in the migration).
