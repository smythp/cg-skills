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
group of them:

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
   invocation (including `--target` if the user builds with one).
2. Run `scripts/compare-images.sh` on the two final images: packages, files,
   libraries.
3. Compare the image configs (next section).
4. Run the remaining functional tests (below).

The gate passes only when both images build, the comparisons were actually
performed, every difference is either resolved or explained in the report,
and the mandatory tests pass. "The compare tool failed so there were no
differences" does not pass — a comparison that was not performed fails the
gate, because an unverified migration that looks finished is the exact
failure this skill exists to prevent.

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
  `docker run --rm --entrypoint <binary> <image> --version` so the check does
  not go through the image entrypoint.
- **File-exists checks**: COPY targets and generated artifacts, via
  `docker create` + `docker cp` (or `compare-images.sh` file output), which
  never executes the image — necessary for distroless images with no shell.
- **Startup and HTTP probe** (skipped only if the user opted out in the
  clarify step): start the migrated container, and if the original exposes a
  port, probe one endpoint. Bind to 127.0.0.1 on an ephemeral port
  (`docker run -d -p 127.0.0.1:0:<port>`, then read the mapped port with
  `docker port`); publishing on all interfaces exposes the container to the
  local network during the test. Where behavior can be compared, run the same
  command against both images and diff the output.

Binary and file checks always run; they are the mandatory floor.

## Timeouts and cleanup

Bound everything that executes, and remove what you start:

- Build: 20 minutes absolute, 5 minutes with no output.
- Pull: 10 minutes.
- `docker save` and SBOM scan: 10 minutes.
- `docker run` checks and probes: 60 seconds by default.
- Detached servers: stop immediately after their probe.
- Every container removed afterwards (`--rm` on one-shot runs;
  `docker rm -f` for detached ones), every temporary image tag noted so the
  user can clean up.

A container that ignores `--help` and serves forever will otherwise hang the
run; the timeout converts a hang into a reported test failure.

## Outcomes: verified and unverified

**Gate passed**: copy `migration-report.md` and `Dockerfile.chainguard` from
the working directory to sit beside the original Dockerfile. Offer — do not
perform — a swap of the original, and only swap on the user's explicit
confirmation, keeping the original as a backup file.

**Gate failed, or could not run**: copy the report and the draft as
`Dockerfile.chainguard.unverified` instead. Say plainly which checks failed
or why validation could not run, and do not offer a swap. Guardener marks
such a run failed; so does this skill. The unverified suffix is the point:
a draft that looks finished gets deployed.

## Report format, with a worked example

Write `migration-report.md` with these sections: Summary, Layer-by-Layer
Changes (with the reason for each change), Package Changes, Config
Differences, Functional Tests, Warnings, and What Was Not Tested. A condensed
real example:

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
  latest (python 3.13) with the user's agreement.

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

- [PASS] python --version (both images; 3.11.9 vs 3.13.2, accepted by user)
- [PASS] python -c "import flask"
- [PASS] file exists: /app/app.py
- [PASS] app startup; HTTP GET / on 127.0.0.1 returned 200

## Warnings

- Original was not digest-pinned, so the migration is not digest-pinned.

## What Was Not Tested

- Production WSGI entry (gunicorn) — no gunicorn invocation in the Dockerfile.
```

Do not pad the report with generic recommendations; every line in it should
be specific to this migration.
