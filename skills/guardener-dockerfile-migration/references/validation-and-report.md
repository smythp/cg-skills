# Validation and the migration report

## Contents

- [Per-layer verification](#per-layer-verification)
- [Prefix builds](#prefix-builds)
- [The final gate](#the-final-gate)
- [Image config comparison](#image-config-comparison)
- [Functional tests](#functional-tests)
- [Timeouts and cleanup](#timeouts-and-cleanup)
- [Outcomes: verified and unverified](#outcomes-verified-and-unverified)
- [Report format, with a worked example](#report-format-with-a-worked-example)

## Per-layer verification

After translating each filesystem instruction (RUN, COPY, ADD) or contiguous
group of them (every build here runs under the build bound — see Timeouts
and cleanup):

1. Build the migrated file up to and including the new lines.
2. Build the original up to the corresponding instruction (cheap — the full
   original build in the capture step warmed Docker's cache).
3. Run `scripts/compare-images.sh` on the pair.
4. Run one focused functional check on the migrated prefix — a binary's
   `--version`, a `python -c "import flask"`, a file-exists — before moving to
   a layer that depends on this one.

The reason for comparing per layer rather than only at the end: a build can
succeed while a library or file quietly went missing. The compare catches
what the build does not, and catching it here costs one layer of rework
instead of a full-file debugging session at the end. Record each check as you
go — the final validation reuses the record instead of re-running everything.

Metadata instructions (ENV, LABEL, EXPOSE, USER, WORKDIR, CMD, ENTRYPOINT,
ARG, VOLUME, SHELL, STOPSIGNAL, HEALTHCHECK) do not change the filesystem;
do not build for them. Translate them directly and verify them in the final
config comparison. Building per metadata line multiplies the run's cost for
nothing.

Emit only lines that were part of the last successful build. If a test build
succeeded without some line, the line does not go in the output.

## Prefix builds

Incremental builds carry everything from the captured invocation — build
args, `--platform`, named contexts, and user-supplied `--secret`/`--ssh`
mounts — except `--target`. A prefix that ends before the target stage is
declared cannot resolve it and the build fails on the flag rather than on
your work. Build the stage you are currently migrating instead. The captured
`--target` applies only to the full baseline build and the final builds in
the gate.

## The final gate

When every layer is done and `scripts/check-from-lines.sh` passes:

1. Build the original and the migrated file in full, each with the captured
   invocation (including `--target` if the user builds with one), each under
   the build bound (`timeout -k 30 1200`).
2. Run `scripts/compare-images.sh` on the two final images: packages, files,
   libraries.
3. Compare the image configs (next section).
4. Run the remaining functional tests (below).

The gate passes only when both images build, the comparisons were actually
performed, every difference is either resolved or explained in the report,
and the mandatory tests pass. "The compare tool failed so there were no
differences" does not pass: a comparison that was not performed fails the
gate, since it cannot show whether anything changed.

## Image config comparison

Compare these fields between the original and migrated final images, from
`docker inspect --format '{{json .Config}}'`:

- `User`, `Env`, `WorkingDir`, `Entrypoint`, `Cmd`, `ExposedPorts`,
  `Volumes`, `Shell`
- `Labels` — but only the LABEL keys the original Dockerfile itself sets.
  Base-image labels always differ between upstream and Chainguard; diffing
  them buries the signal.
- `Healthcheck` — compared as an addition beyond Guardener's field set,
  because a lost HEALTHCHECK silently disables orchestrator health gating.

Every intentional difference gets a sentence in the report: a PATH that now
includes the Chainguard interpreter directory, a User that changed from root
to 65532, an Env the base no longer sets. An unexplained difference is
unfinished work, not a footnote.

## Functional tests

Run at most ten to fifteen focused tests in the gate, skipping anything the
per-layer record already covers:

- **Binary checks**: key binaries with `--version` or equivalent. On images
  whose entrypoint is the runtime binary, use
  `timeout -k 30 60 docker run --rm --name migr-$RUN_ID-check-1 --entrypoint <binary> <image> --version`
  (`$RUN_ID` is the run identifier from SKILL.md step 5; a unique `--name`
  per check, removed afterwards with
  `docker rm -f migr-$RUN_ID-check-1 >/dev/null 2>&1 || true`) so the check does not
  go through the image entrypoint and cannot hang past the 60-second run
  bound, and a timed-out check leaves nothing running daemon-side.
- **File-exists checks**: COPY targets and generated artifacts, via
  `docker create` + `docker cp` (or `compare-images.sh` file output), which
  never executes the image — necessary for distroless images with no shell.
- **Startup and HTTP probe** (skipped only if the user opted out in the
  clarify step): start the migrated container named and detached, and if the
  original exposes a port, probe one endpoint. Bind to 127.0.0.1 on an
  ephemeral port
  (`timeout -k 30 60 docker run -d --name migr-$RUN_ID-app -p 127.0.0.1:0:<port> <image>`,
  then read the mapped port with `docker port migr-$RUN_ID-app`);
  publishing on all interfaces exposes the container to the local network
  during the test. The detached `docker run -d` returns as soon as the
  container starts, but the client carries the 60-second bound like every
  `docker run` in the workflow — a stuck daemon or implicit pull would
  otherwise hang it. The same bound applies to the probe itself
  (`timeout -k 30 60 curl -fsS http://127.0.0.1:<mapped-port>/`), and the
  container is removed right after it, pass, fail, or timeout
  (`docker rm -f migr-$RUN_ID-app >/dev/null 2>&1 || true`). Where behavior can
  be compared, run the same command against both images and diff the output.

Binary and file checks always run; they are the mandatory floor.

## Timeouts and cleanup

Bound everything that executes, and remove what you start. The bundled lookup
and comparison scripts bound their internal docker calls with the `timeout`
utility on their own; every docker command the workflow itself issues is
written with `timeout -k 30 <seconds>` inline.

- Build: 20 minutes —
  `timeout -k 30 1200 docker build ... > <workdir>/build.log 2>&1`
  (keep the log in the working directory; the build-fix playbook reads it).
- Pull: 10 minutes — `timeout -k 30 600 docker pull <image>`.
- `docker save` and SBOM scan: 10 minutes, enforced inside
  `scripts/compare-images.sh`.
- `docker run` checks and probes: 60 seconds —
  `timeout -k 30 60 docker run --rm --name migr-$RUN_ID-check-1 ...` — and the
  bound goes on detached (`-d`) starts too; it covers the client, not the
  server the container runs.
- Detached servers: remove immediately after their probe.
- `timeout` kills only the docker client; a container the run started keeps
  running daemon-side. Every container the workflow starts therefore gets a
  `--name` built from the step-5 run identifier (`migr-$RUN_ID-<purpose>` —
  a fixed name would collide across concurrent runs), removed after the
  check or after a timeout
  (`docker rm -f migr-$RUN_ID-check-1 >/dev/null 2>&1 || true`); every temporary
  image tag is noted so the user can clean up.

A build stuck on one step, or a container that ignores `--help` and serves
forever, would otherwise hang the run; the bounds convert a hang into a
reported failure (`timeout` exits 124).

## Outcomes: verified and unverified

**Gate passed**: copy `migration-report.md` and `Dockerfile.chainguard` from
the working directory to sit beside the original Dockerfile. Offer — do not
perform — a swap of the original, and only swap on the user's explicit
confirmation, keeping the original as a backup file.

**Gate failed, or could not run**: copy the report and the draft as
`Dockerfile.chainguard.unverified` instead. Say plainly which checks failed
or why validation could not run, and do not offer a swap. Guardener marks
such a run failed; so does this skill. The suffix marks the file as
unverified for anyone who finds it later.

## Report format, with a worked example

Write `migration-report.md` with these sections: Summary, Layer-by-Layer
Changes (with the reason for each change), Package Changes, Config
Differences, Functional Tests, Warnings, and What Was Not Tested. When an
organization registry or mirror is in play, Warnings carries one sentence
per image that fell back to the public `cgr.dev/chainguard` catalog, naming
the image and the reason (for example: ruby is not in your org, so the
public `cgr.dev/chainguard/ruby` was used).

Warnings also carries a Resolved digests line: for every FROM that names a
registry image (`scratch` and stage aliases have no digest), the digest it
resolved to — through
`chainctl images tags list` for a Chainguard registry, or for a mirror the
manifest digest (`timeout -k 30 60 docker manifest inspect -v <ref>`) — and
whether it was pinned (pinned: original was pinned, or the user opted in,
with a reminder to keep the digest current with digestabot or Renovate;
not pinned: original unpinned and no opt-in). A condensed real example:

```markdown
# Migration Report: flask-app

## Summary

- Status: verified — both images build, comparisons performed, 9/9 tests passed
- Original base: python:3.11-slim
- Migrated base: cgr.dev/chainguard/python:latest-dev (build), cgr.dev/chainguard/python:latest (runtime)
- Build invocation: docker build -t flask-app .

## Layer-by-Layer Changes

### FROM python:3.11-slim
- Migrated: FROM cgr.dev/chainguard/python:latest-dev AS builder
- Purpose-built python image over wolfi-base; -dev variant because the stage
  runs pip. Public catalog serves latest/latest-dev, so the 3.11 pin became
  latest with the user's agreement; the no-drift alternative (wolfi-base plus
  the python-3.11 apk package) was offered and declined.

### RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
- Migrated: USER root / RUN apk add --no-cache curl / USER 65532
- apt translated to apk; cache cleanup dropped (--no-cache); wrapped in
  USER root because the python image runs as 65532.

### RUN pip install --no-cache-dir -r requirements.txt
- Unchanged command; runs in the -dev builder stage.

## Package Changes

- Added (wolfi): curl
- requirements.txt unchanged: flask==3.1.3, gunicorn==22.0.0 install from PyPI.
  For hardened language dependencies, see Chainguard Libraries (libraries.cgr.dev).

## Config Differences

- User: "" -> 65532 (intentional: Chainguard image is non-root)
- Env PATH: gained /usr/share/python/bin (interpreter location in the new base)
- Cmd: unchanged ["python", "app.py"]; verified against the image ENTRYPOINT

## Functional Tests

- [PASS] python --version (both images; the original's pinned 3.11 vs the
  migrated image's latest — the version drift the user accepted)
- [PASS] python -c "import flask"
- [PASS] file exists: /app/app.py
- [PASS] app startup; HTTP GET / on 127.0.0.1 returned 200

## Warnings

- Original was not digest-pinned, so the migration is not digest-pinned.
- Resolved digests:
  cgr.dev/chainguard/python:latest-dev@sha256:df9eb3812f118b33f8fd0bafb7efa0112d6a0810b40b2707337a4c432845f7b4
  (not pinned: original unpinned and no opt-in);
  cgr.dev/chainguard/python:latest@sha256:780029a86e72bf3a58b1795cb77ab73b8f48dfea8c94ab154345396dc3d3237a
  (not pinned: original unpinned and no opt-in).

## What Was Not Tested

- Production WSGI entry (gunicorn) — no gunicorn invocation in the Dockerfile.
```

Do not pad the report with generic recommendations; every line in it should
be specific to this migration.
