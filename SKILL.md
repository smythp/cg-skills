---
name: guardener-dockerfile-migration
description: >-
  Migrates a Dockerfile onto Chainguard Containers with build verification:
  translates the file layer by layer, builds original and migrated images
  with Docker, compares packages, files, and image config, runs functional
  tests, and writes a migration report. Use when asked to migrate, convert,
  rewrite, or harden a Dockerfile to Chainguard images (cgr.dev) and Docker
  is available to verify the result; requires Docker and chainctl, and a
  full run takes five to thirty minutes of builds. Not for GitHub Actions
  workflow migrations, Helm charts or Kubernetes manifests, apko or melange
  image builds, Chainguard Libraries (language dependency) setup, or images
  that have no Dockerfile source. For a quick rules-only rewrite without
  Docker, use a static Dockerfile migration skill instead.
metadata:
  derived_from: >-
    Guardener dfc v2 (chainguard-dev/mono containers/dfc; Billy Lynch, Alex
    Buchanan, Rahul Duvedi, Carlos Tadeu Panato Junior, Jonathan Lange,
    Maxime Gréau, Evan Gibler, Kenny Leung, Ajay Kemparaj); dockerfile-migrator
    (Patrick Smyth) and migrating-dockerfiles-to-chainguard (Lisa Tagliaferri),
    chainguard-demo/claude-plugins; chainguard-migrate-dockerfile (iamfuzz,
    chainguard-dev/mono cursor plugin); Chainguard Power for Kiro (iamfuzz,
    Brian Thomason, Jonathan Lange, Jason Meridth); dfc CLI (chainguard-dev/dfc).
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# Guardener Dockerfile migration

Migrate one Dockerfile (single or multi-stage) onto Chainguard Containers,
and prove the result: the migrated image builds, keeps every FROM on an
allowed Chainguard source, runs as the image's non-root user, matches the
original's packages and configuration except where the report explains the
difference, and passes functional checks. A run that cannot meet that bar
says so and leaves a clearly-marked unverified draft — never a file that
looks finished.

The loop is translate → build → compare → test, per layer, then a final
validation gate. Builds are real execution: a `docker build` ships the whole
context to the daemon and RUN lines run with network access, which is why the
workflow gates the first build on the user's confirmation and never adds
credentials of its own.

Copy this checklist into your reply and tick items as you complete them:

```
- [ ] 1. Preflight passed
- [ ] 2. User confirmed the build after a summary of what it does
- [ ] 3. Build invocation captured; original built as the baseline
- [ ] 4. Org / mirror / FIPS / probe preferences clarified
- [ ] 5. Working directory created outside the build context
- [ ] 6. File mapped: stages, package managers, referenced context files
- [ ] 7. Optional dfc draft taken or skipped
- [ ] 8. Every layer translated, built, compared, and tested
- [ ] 9. Build failures fixed with the playbook (or none occurred)
- [ ] 10. FROM gate passed; stage-end USER verified
- [ ] 11. Final validation gate passed (or run marked unverified)
- [ ] 12. Report written; outputs delivered; swap only on confirmation
```

## The workflow

### 1. Preflight

Run `scripts/preflight.sh <context-dir>`. If Docker is not running or
chainctl is missing or logged out, stop and tell the user what to fix.
Without Docker there is no verification, and an unverified migration is
exactly the failure this skill exists to prevent — do not fall back to
guessing; point the user at a static rules-only migration skill instead.

### 2. Trust gate — always

Read the Dockerfile and the `.dockerignore`, then summarize in a few lines
what the build does: what it fetches, what it executes, what the context
directory exposes to the daemon. Get the user's confirmation before the
first build. This is not skipped for files the user says are their own —
the point is that the user sees what is about to execute, not that the file
is suspected.

### 3. Capture the build

Record the exact invocation that builds the original today: context path,
`-f`, every `--build-arg`, `--platform`, `--target`, named contexts, and any
`--secret` or `--ssh` mounts the user already passes. Build the original once
with it, under the build bound like every build in this workflow
(`timeout -k 30 1200 docker build ...`; bounds in the Time and cleanup
section). If the original does not build
locally, stop and say so — with no baseline there is nothing to compare a
migration against, and migrating blind produces exactly the unverifiable
file this skill refuses to emit.

Credential rule: never add, discover, or forward credentials on your own —
no SSH agent, no Docker socket mounts, no secrets lifted from the
environment, no `--privileged` or host-network builds. Mounts the user
supplied in the captured invocation pass through unchanged and are named in
the report.

### 4. Clarify, once

Read `~/.config/chainguard/dockerfile-migration-preferences.md` first; if it
exists, use its answers and ask only what it does not cover. The path is
deliberately agent-neutral — any agent running this skill finds the same
answers there. Then ask the rest together, in one message:

- **Organization**: resolve from `chainctl iam organizations list`. Exactly
  one → use it and say so. Several → list them and ask. None → use
  `cgr.dev/chainguard` (the public catalog) and say so.
- **External mirror**: is there a pull-through mirror prefix to prefer?
- **FIPS**: are FIPS images required? (FIPS variants carry a `-fips`
  suffix, e.g. `python-fips`.)
- **Probes**: run app startup and HTTP probes during validation? Binary and
  file checks always run regardless.

Offer to save new answers to that preferences file for later migrations;
write it only after the user confirms.

### 5. Work outside the build context

Create a temporary directory with `mkdir` + `chmod 700` **outside** the build
context for the evolving Dockerfile, report draft, build logs, and archives,
and build with `-f` pointing there. A working file inside the context gets
swept up by `COPY . .` — it contaminates the migrated image, invalidates the
comparison, and busts Docker's layer cache on every edit. Nothing is written
beside the original until step 12, and the original file is never edited.

### 6. Map the file

List the stages, the base image and package manager per stage, and classify
every instruction: filesystem (RUN, COPY, ADD) or metadata (everything
else). Read the context files the Dockerfile references — `requirements.txt`,
`package.json`, `go.mod` — because they decide which packages the runtime
needs. Note any `pip`, `npm`, or `mvn` usage: the report gets a one-line
pointer to Chainguard Libraries for those (see
`references/package-translation.md`).

If a base image is a deep stack with no one-line equivalent (ros,
tensorflow, a vendor image), plan the stage with
`references/complex-bases.md` before translating line by line.

### 7. Optional deterministic draft

If the `dfc` CLI is installed, run
`dfc --org=<org> ./Dockerfile > <workdir>/Dockerfile.draft` (or
`dfc --registry=<mirror-prefix> ...` when a mirror is configured) and treat
every line of the draft as untested input: it saves time on the easy lines,
and nothing from it is emitted until step 8 verifies it. If dfc is not
installed, skip this — do not install anything for it.

### 8. Migrate layer by layer, in order, per stage

For each instruction, using `references/from-and-registry-rules.md`,
`references/package-translation.md`, and
`references/users-entrypoints-paths.md`:

- **FROM**: pick the target image and tag per the registry rules. On the
  public catalog, when the original pins a version whose major.minor does not
  match the purpose-built image's `latest`, ask the user to choose between
  purpose-built `latest` (accepting the version drift) and `wolfi-base` plus
  the versioned apk package (no drift); running unattended, take `wolfi-base`
  plus the versioned apk package — a migration must not change the runtime
  version without consent. Confirm the image exists and get its digest via
  the avenues in `references/lookup-avenues.md`; pull it
  (`timeout -k 30 600 docker pull <image>`) and record
  its config (`docker inspect`: user, entrypoint, cmd, env, workdir) — the
  USER discipline and the config comparison both need it.
- **RUN**: translate the package manager; validate every package name with
  `scripts/apk-lookup.sh` before building; drop `ca-certificates`; wrap
  root-needing RUNs in `USER root` … `USER <image user>` in the same block.
  If a package is dropped, apply the internal-consistency rule.
- **COPY/ADD**: keep; fix ownership for the non-root user; remap
  postgres-family init-script paths.
- **Metadata**: pass through; do not add base-image defaults the original
  overrides; check CMD against a purpose-built image's ENTRYPOINT.

After each filesystem instruction or contiguous group: build the migrated
prefix, build the original prefix to the same point (cheap — step 3 warmed
the cache; both builds under the build bound), run
`scripts/compare-images.sh` on the pair, and run one focused
functional check before touching a layer that depends on this one. A build
that succeeds while a library went missing is what the compare catches and
the build does not. Record every check; step 11 reuses the record.

Prefix builds carry the captured build args, platform, contexts, and
user-supplied mounts — but not `--target` (a prefix ending before that stage
cannot resolve it; build the current stage instead). Emit only lines that
were in the last successful build.

Details, including what not to build for: `references/validation-and-report.md`.

### 9. Fix failed builds

Use `references/build-fix-playbook.md`: read the error and its surrounding
log, apply the matching fix, rebuild. A pull or auth failure is reported to
the user — it is never solved by switching to another registry.

### 10. Gate the FROMs

Run `scripts/check-from-lines.sh` on the complete migrated file, with
`--mirror <prefix>` if one is configured and a repeated `--build-arg
NAME=value` for every build arg in the captured invocation — the build honors
those overrides over the Dockerfile's ARG defaults, so a gate run without
them checks a different file than the one being built. Any FROM outside the allowlist
fails the run — fix it, do not argue with the gate. Then confirm every stage
that used `USER root` ends with the image's user. This is the
machine-checkable intermediate output: paste its OK line into your reply
before proceeding.

### 11. Validate — a hard gate

Build both files in full with the captured invocation (including `--target`),
each under the build bound (`timeout -k 30 1200`).
Run `scripts/compare-images.sh` on the final images, compare the image
configs field by field, and run the remaining functional tests, all per
`references/validation-and-report.md`. The gate passes only when both images
build, the comparisons were actually performed, every difference is resolved
or explained, and the mandatory tests pass. A comparison that could not be
performed fails the gate — it is not an empty diff.

### 12. Report and hand over

Write `migration-report.md` in the format shown in
`references/validation-and-report.md`. If step 11 passed, copy the report
and `Dockerfile.chainguard` beside the original and offer — do not perform —
a swap of the original on the user's confirmation. If it did not pass, copy
the report and `Dockerfile.chainguard.unverified` instead, say plainly why,
and do not offer a swap.

## Hard rules

These are the rules whose violation is irreversible or silently wrong. Each
reference file carries the detail; the one-line forms:

1. **FROM allowlist**: every FROM stays on `cgr.dev/*`, the configured
   mirror, `scratch`, or a declared stage alias — a FROM that drifts
   produces an image nobody maintains, and `scripts/check-from-lines.sh`
   rejects it.
2. **Never swap registries to make a pull work**: report the underlying
   error instead; a swapped registry is a migration that silently stopped
   being one.
3. **Emit only tested lines**: untested lines are where final builds die.
4. **Stage-end USER invariant**: a stage that went `USER root` ends as the
   image user, or the final image runs as root — a security regression.
5. **Internal consistency**: a dropped package takes its ENV, ARG, symlinks,
   and invocations with it, or the file builds and lies.
6. **Never install ca-certificates**: the bundle is already in every
   Chainguard image.
7. **No credentials of your own** (step 3): user-supplied mounts pass
   through; nothing else does.
8. **Digest rule**: pinned original → migration pinned to the Chainguard
   image's own digest; unpinned stays unpinned; mirror digests come from
   RepoDigests or are dropped with a warning
   (`references/from-and-registry-rules.md` documents the one deliberate
   deviation from Guardener here).

When running unattended with no user to ask, prefer any real migration path
over keeping the original image — but the trust gate (step 2) and the swap
confirmation (step 12) still require a human; without one, stop at the
report instead of swapping files.

## Time and cleanup bounds

Absolute bounds, one per command class: builds 20 minutes (1200 s), pulls
10 minutes (600 s), `docker save` and SBOM scans 10 minutes (600 s),
container runs and probes 60 seconds. Probes bind to 127.0.0.1 on an
ephemeral port; detached servers are stopped right after their probe.
Package-index lookups (`scripts/apk-lookup.sh`) download the apk index over
the network, so their container run gets the 10-minute bound, not the
60-second probe bound. A stalled build or a container that serves forever
would otherwise hang the run; the bound converts the hang into a reported
failure (`timeout` exits 124).

Enforcement is split by who runs the docker command. The bundled scripts
(`scripts/apk-lookup.sh`, `scripts/compare-images.sh`) bound their internal
docker calls with the `timeout` utility and refuse to run docker without it;
preflight checks for it. Every docker command the workflow itself issues —
build, pull, run, save, probe — is written with `timeout -k 30 <seconds>`
inline:

```sh
timeout -k 30 1200 docker build -t app-migrated -f "$workdir/Dockerfile.chainguard" . > "$workdir/build.log" 2>&1
timeout -k 30 600 docker pull cgr.dev/chainguard/python:latest
```

`timeout` kills only the docker client; a container the run started keeps
running daemon-side. So every container the workflow starts — a probe, a
functional check, a detached server — gets a `--name` unique to that run,
and the name is removed right after the check or after a timeout:

Correct:

```sh
timeout -k 30 60 docker run --rm --name migr-probe-1 --entrypoint python cgr.dev/chainguard/python:latest --version
docker rm -f migr-probe-1 >/dev/null 2>&1 || true
```

Wrong (no `--name`: when the run times out, the client dies but the
container keeps running on the daemon with nothing to remove it by):

```sh
timeout -k 30 60 docker run --rm cgr.dev/chainguard/python:latest --version
```

Tell the user up front that a full run is five to thirty minutes of builds.
