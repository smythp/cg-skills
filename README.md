# guardener-dockerfile-migration

Migrate a Dockerfile onto Chainguard Containers and prove the result. The
skill runs Guardener's migration method as an agent skill: translate the
file layer by layer, build the original and the migrated image with Docker,
compare packages, files, and image configuration, run functional tests, and
write a migration report. A run that cannot verify its output says so and
leaves a clearly-marked unverified draft instead of a file that looks
finished.

## Which migration skill to use

- **This one** when Docker is available and you want a build-verified
  result. A full run takes five to thirty minutes of builds.
- **A static rules-only skill** (such as `dockerfile-migrator`) for a quick
  rewrite without Docker — same mapping rules, no verification.

## Requirements

- Docker with a running daemon
- `chainctl`, logged in (`chainctl auth login`)
- Optional: `syft` (otherwise a syft container is used for image
  comparison), `dfc` (optional deterministic first draft)

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
  Docker with registry egress; the two doc guards, `test-docs-bounded.sh`
  (every docker build/pull/run/save/exec line in the docs carries
  `timeout -k 30`) and `test-docs-container-names.sh` (every `--name` uses
  the `migr-$RUN_ID-` run identifier), need only sh and awk.

## Version

0.1.0 — first packaged release of the Guardener migration method as a
standalone skill.

## Credits and sources

Distilled from Guardener dfc v2 (chainguard-dev/mono, containers/dfc): its
layer, fixer, and validation prompts, FROM validation, registry preference
rules, client-side image comparison tools, and report format and test types.
Authors: Billy Lynch, Alex Buchanan, Rahul Duvedi, Carlos Tadeu Panato
Junior, Jonathan Lange, Maxime Gréau, Evan Gibler, Kenny Leung, Ajay
Kemparaj.

Prior art folded in: `dockerfile-migrator` (Patrick Smyth) and
`migrating-dockerfiles-to-chainguard` (Lisa Tagliaferri) from
chainguard-demo/claude-plugins; `chainguard-migrate-dockerfile` (iamfuzz);
Chainguard Power for Kiro (iamfuzz, Brian Thomason, Jonathan Lange, Jason
Meridth); the open-source dfc CLI (chainguard-dev/dfc).
