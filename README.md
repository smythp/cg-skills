# guardener-dockerfile-migration

Migrate a Dockerfile onto Chainguard Containers and verify the result with
real builds. The skill runs Guardener's migration method as an agent skill: translate the
file layer by layer, build the original and the migrated image with Docker,
compare packages, files, and image configuration, run functional tests, and
write a migration report. When the final validation gate does not pass, the
run writes the report with the reasons and leaves the draft as
`Dockerfile.chainguard.unverified`; no file swap is offered.

## Requirements

- Docker with a running daemon
  (install: https://docs.docker.com/get-docker/). Docker is required;
  Podman is not supported in this version.
- `chainctl`, logged in with `chainctl auth login`, which is interactive
  (install: https://edu.chainguard.dev/platform/chainctl-usage/how-to-install-chainctl/)
- `timeout` — GNU coreutils or BusyBox; on macOS `brew install coreutils`
  provides it as `gtimeout`. Without it the scripts run docker without a
  time bound and preflight says so.
- Optional: `syft` (install: https://github.com/anchore/syft#installation;
  otherwise a syft container is used for image comparison)

The skill does not install these. `scripts/preflight.sh` checks each one
and, for anything missing, tells the user what is missing and where the
install instructions are; the user decides whether to install it or to ask
their agent to. Without `syft` the pinned scanner container is used.

## Install

```sh
chainctl skills install skills.cgr.dev/chainguard/chainguard-dev/guardener-dockerfile-migration:latest
```

For local development, copy this directory into your agent's skills
directory instead.

## Layout

- `SKILL.md` — the workflow
- `references/` — FROM and registry rules, package translation, USER and
  entrypoint discipline, complex bases, build-fix playbook, validation and
  report format, lookup avenues
- `scripts/` — `preflight.sh`, `apk-lookup.sh`, `check-from-lines.sh`
  (FROM allowlist gate), `compare-images.sh`, and their tests under
  `scripts/tests/`: run each suite with `sh scripts/tests/<name>.sh`.
  `test-check-from-lines.sh` needs no Docker; `test-compare-images.sh` needs
  Docker with registry egress; `test-preflight.sh` (the organization listing
  must fail loudly on empty or non-JSON output) shims docker and chainctl,
  so it needs neither; the two doc guards, `test-docs-bounded.sh`
  (every docker build/pull/run/save/exec/manifest line in the docs carries
  `timeout -k 30`) and `test-docs-container-names.sh` (every `--name` uses
  the `migr-$RUN_ID-` run identifier), need only sh and awk; so does
  `test-docs-guards-selfcheck.sh`, which seeds known violations into a temp
  doc tree and asserts both guards catch each one by file:line.
- `evals/` — end-to-end harness: six before/after fixtures whose
  original builds and whose skill-regenerated `Dockerfile.chainguard` are
  built, gated, and smoke-tested with real Docker (`evals/run.sh`; see
  `evals/README.md`).

## Version

0.1.0 — first packaged release of the Guardener migration method as a
standalone skill.
