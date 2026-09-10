#!/usr/bin/env bash
# End-to-end harness for guardener-dockerfile-migration.
#
# For each fixture under tests/e2e/fixtures/, this:
#   1. Builds the original Dockerfile ("before") and runs its smoke test
#      (sanity — a failure here is ERROR, a fixture bug, not a migration
#      failure)
#   2. Resolves the org into a temp copy of the expected Dockerfile.chainguard
#   3. Gates the resolved file: FROM allowlist (scripts/check-from-lines.sh)
#      and the stage-end USER rule (below)
#   4. Builds the resolved file ("after") and runs its smoke test (the real
#      assertion)
#
# A fixture PASSES only when both gates pass AND the converted image builds
# AND the smoke test succeeds. A fixture whose expected file is
# Dockerfile.chainguard.unverified is reported UNVERIFIED — the migration
# gate did not pass when the file was regenerated — and makes the run exit
# non-zero. A fixture with no expected file at all is SKIP.
#
# This harness is bash — it is a maintainer tool that needs Docker anyway;
# the POSIX-sh rule applies to scripts/, not to tests/e2e/.
#
# Usage:
#   tests/e2e/run.sh                 # run all fixtures
#   tests/e2e/run.sh python-flask    # run named fixture(s)
#
# Env:
#   TEST_ORG     cgr.dev org substituted for the public "chainguard" org in
#                Dockerfile.chainguard (default: unset — the expected files
#                stay on the public catalog, so anyone can run the harness
#                with no Chainguard entitlement)
#   SKILL_DIR    the skill directory holding scripts/ (default: two levels
#                above this script — the harness's one path assumption, so a
#                git mv of tests/e2e/ means changing this default alone)
#   SKIP_BEFORE=1   skip the "before" sanity build (faster iteration)
#   KEEP_IMAGES=1   don't remove built images afterwards
#
# Adapted from Adrian Mouat's dfc-skillz (amouat/dfc-skillz) tests/run.sh.
# Changes from his version: the expected file is Dockerfile.chainguard (the
# skill's output name), the two gate checks and the UNVERIFIED outcome are
# new, builds carry the workflow's inline time bound, containers and image
# tags carry a per-run identifier, and cleanup runs from a trap.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$ROOT/fixtures"
SKILL_DIR="${SKILL_DIR:-$(cd "$ROOT/../.." && pwd)}"
RUN_ID="$(date +%s)-$$"
# shellcheck source=lib.sh
source "$ROOT/lib.sh"

RESOLVED_DIR="$(mktemp -d)"
declare -a CLEANUP_CONTAINERS CLEANUP_IMAGES

harness_cleanup() {
  local c i
  for c in "${CLEANUP_CONTAINERS[@]-}"; do
    [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1
  done
  if [ "${KEEP_IMAGES:-0}" != "1" ]; then
    for i in "${CLEANUP_IMAGES[@]-}"; do
      [ -n "$i" ] && docker image rm -f "$i" >/dev/null 2>&1
    done
  fi
  rm -rf "$RESOLVED_DIR"
  return 0
}
trap harness_cleanup EXIT INT TERM

pass=0 fail=0 err=0 unverified=0
declare -a RESULTS

# stage_end_user_check DOCKERFILE
# Every stage that switches to USER root (or USER 0) must end with a USER
# line naming a non-root user before the next FROM or end of file — a stage
# left as root ships a root-running image (SKILL.md hard rule 4).
stage_end_user_check() {
  awk '
    function flush_stage(   u) {
      if (!saw_root) return
      u = last_user; sub(/:.*/, "", u)
      if (u == "" || u == "root" || u == "0") {
        printf "  stage starting at line %d switches to USER root and ends as %s\n", \
          stage_line, (last_user == "" ? "root (no later USER)" : last_user) > "/dev/stderr"
        bad = 1
      }
    }
    toupper($1) == "FROM" { flush_stage(); saw_root = 0; last_user = ""; stage_line = NR; next }
    toupper($1) == "USER" {
      last_user = $2
      u = $2; sub(/:.*/, "", u)
      if (u == "root" || u == "0") saw_root = 1
      next
    }
    END { flush_stage(); exit bad }
  ' "$1"
}

# build_and_smoke LABEL DOCKERFILE CONTEXT_DIR FIXTURE_DIR IMAGE_TAG CONTAINER_NAME
# echoes "ok" / "build-fail" / "smoke-fail"
build_and_smoke() {
  local label="$1" dockerfile="$2" ctx="$3" fixdir="$4" tag="$5" cname="$6"
  local logf; logf="$(mktemp)"
  if ! timeout -k 30 1200 docker build -q -t "$tag" -f "$dockerfile" "$ctx" >"$logf" 2>&1; then
    echo "  [$label] build FAILED:" >&2
    sed 's/^/    /' "$logf" >&2
    rm -f "$logf"
    echo "build-fail"; return
  fi
  rm -f "$logf"
  if [ -f "$fixdir/smoke.sh" ]; then
    # smoke output goes to stderr: this function reports its result on stdout,
    # and a smoke script that prints (django's does) must not pollute it
    if E2E_CONTAINER="$cname" bash "$fixdir/smoke.sh" "$tag" >&2; then
      echo "ok"
    else
      echo "  [$label] smoke test FAILED" >&2
      echo "smoke-fail"
    fi
  else
    echo "ok"  # no smoke test defined => build success is enough
  fi
}

run_fixture() {
  local dir="$1" name; name="$(basename "$dir")"
  echo "==> $name"

  local before="$dir/Dockerfile" after="$dir/Dockerfile.chainguard"

  if [ -f "$dir/Dockerfile.chainguard.unverified" ]; then
    RESULTS+=("UNVERIFIED  $name  (the migration gate did not pass at regeneration; see its migration-report.md)")
    ((unverified++)); return
  fi
  if [ ! -f "$after" ]; then
    RESULTS+=("SKIP  $name  (no Dockerfile.chainguard — not yet converted)")
    return
  fi

  local tag_before="migr-e2e-$RUN_ID-$name-before" tag_after="migr-e2e-$RUN_ID-$name-after"
  local cn_before="migr-e2e-$RUN_ID-$name-smoke-before" cn_after="migr-e2e-$RUN_ID-$name-smoke-after"
  CLEANUP_CONTAINERS+=("$cn_before" "$cn_after")
  CLEANUP_IMAGES+=("$tag_before" "$tag_after")

  # 1. before (sanity)
  if [ "${SKIP_BEFORE:-0}" != "1" ] && [ -f "$before" ]; then
    local b; b="$(build_and_smoke before "$before" "$dir" "$dir" "$tag_before" "$cn_before")"
    if [ "$b" != "ok" ]; then
      RESULTS+=("ERROR $name  (before/$b — fixture bug)")
      ((err++)); return
    fi
  fi

  # 2. Resolve the org into a temp copy outside the build context, so the
  #    fixtures aren't hard-wired to one org and the working copy is never
  #    swept up by COPY . .
  local resolved="$RESOLVED_DIR/$name.Dockerfile.chainguard"
  if [ -n "${TEST_ORG:-}" ]; then
    sed "s#cgr.dev/chainguard/#cgr.dev/$TEST_ORG/#g" "$after" >"$resolved"
  else
    cp "$after" "$resolved"
  fi

  # 3. FROM allowlist gate
  if ! sh "$SKILL_DIR/scripts/check-from-lines.sh" "$resolved" >&2; then
    RESULTS+=("FAIL  $name  (check-from-lines rejected a FROM)")
    ((fail++)); return
  fi

  # 4. stage-end USER gate
  if ! stage_end_user_check "$resolved"; then
    RESULTS+=("FAIL  $name  (a stage switches to USER root and never drops it)")
    ((fail++)); return
  fi

  # 5 + 6. after (the real assertion): build, then smoke
  local a; a="$(build_and_smoke after "$resolved" "$dir" "$dir" "$tag_after" "$cn_after")"
  case "$a" in
    ok)         RESULTS+=("PASS  $name"); ((pass++)) ;;
    build-fail) RESULTS+=("FAIL  $name  (converted image build failed)"); ((fail++)) ;;
    smoke-fail) RESULTS+=("FAIL  $name  (converted image smoke test failed)"); ((fail++)) ;;
  esac

  if [ "${KEEP_IMAGES:-0}" != "1" ]; then
    docker image rm -f "$tag_before" "$tag_after" >/dev/null 2>&1 || true
  fi
}

main() {
  local targets=("$@")
  if [ ${#targets[@]} -eq 0 ]; then
    for d in "$FIXTURES"/*/; do targets+=("$(basename "$d")"); done
  fi
  local name
  for name in "${targets[@]}"; do
    [ -d "$FIXTURES/$name" ] || { echo "no such fixture: $name" >&2; continue; }
    run_fixture "$FIXTURES/$name"
  done

  echo
  echo "================ RESULTS ================"
  printf '%s\n' "${RESULTS[@]-}"
  echo "----------------------------------------"
  echo "pass=$pass fail=$fail error=$err unverified=$unverified  (org=${TEST_ORG:-chainguard})"
  [ "$fail" -eq 0 ] && [ "$err" -eq 0 ] && [ "$unverified" -eq 0 ]
}

main "$@"
