# End-to-end harness

Proves, with real Docker builds, that the migrations this skill produces
hold up: for every fixture, the original Dockerfile still builds and passes
its smoke test (so the fixture itself is valid), and the expected
`Dockerfile.chainguard` passes the skill's FROM allowlist gate and stage-end
USER rule, builds, and passes the same smoke test. The harness exercises the
skill's *outputs*; it does not run the skill.

This harness is written in bash — it is a maintainer tool that needs Docker
anyway; the POSIX-sh portability rule applies to `scripts/`, not to
`evals/`.

The directory is named `evals/` because that is the name the Agent Skills
documentation and Claude Code's plugin eval tooling use for a skill's own
evaluations, so those tools find it where they expect. `chainctl skills
validate` prints exactly which files a push would publish; run it to see
whether this directory ships in the artifact.

## Running it

```sh
evals/run.sh                 # all fixtures
evals/run.sh python-flask    # one or more named fixtures
```

Requirements: Docker with a running daemon, bash, curl, `timeout`. The
expected files reference the public `cgr.dev/chainguard` catalog, so no
Chainguard entitlement is needed.

Each fixture reports one of:

- **PASS** — gates passed, converted image built, smoke test passed.
- **FAIL** — a gate rejected the expected file, its build failed, or its
  smoke test failed.
- **ERROR** — the *original* build or smoke failed: a fixture bug, not a
  migration failure.
- **UNVERIFIED** — the fixture's expected file is
  `Dockerfile.chainguard.unverified`: the skill's validation gate did not
  pass when the file was regenerated (its migration-report.md says why).
  Distinct from PASS and FAIL, and the run exits non-zero.
- **SKIP** — no expected file yet.

The run exits 0 only when every fixture is PASS or SKIP.

## Knobs

- `TEST_ORG` — substitute a customer org for the public `chainguard` org in
  the expected files (`sed cgr.dev/chainguard/ → cgr.dev/$TEST_ORG/`) to run
  the same fixtures against an org catalog. Default: unset, the public
  catalog.
- `SKILL_DIR` — where the skill's `scripts/` live. Defaults to one level
  above `run.sh`; this is the harness's only path assumption, so moving
  `evals/` elsewhere means updating one default.
- `SKIP_BEFORE=1` — skip the "before" sanity build for faster iteration.
- `KEEP_IMAGES=1` — keep the built images for inspection afterwards.

Every build, pull, and container run carries an inline `timeout -k 30`
bound; containers and image tags carry a per-run identifier
(`migr-e2e-$RUN_ID-<fixture>-<purpose>`), and cleanup runs from a trap on
EXIT, INT, and TERM.

## Adding a fixture

Create `evals/fixtures/<name>/` with:

- `Dockerfile` — the original, unmigrated file.
- The build context it needs (source files, requirements, and so on).
- `smoke.sh` — a per-fixture check run against both images; it receives the
  image tag as `$1` and exits non-zero on failure. Source `../../lib.sh`
  and start containers through `run_detached` (which publishes on an
  ephemeral 127.0.0.1 port and echoes the resolved `host:port`) or with
  `--name "$E2E_CONTAINER"` and an inline `timeout`, so the harness can
  clean up after a hang.
- `Dockerfile.chainguard` and `migration-report.md` — regenerated, never
  written by hand: run this skill's SKILL.md end to end as the agent against
  the fixture's Dockerfile and place exactly what the skill produced after
  its validation gate. If the gate fails, place
  `Dockerfile.chainguard.unverified` and the report instead — do not edit
  the file into a passing state. Scrub absolute paths, run identifiers, and
  timestamps from the report so it neither rots nor leaks the machine it
  was generated on.
