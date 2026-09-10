#!/bin/sh
# Self-check for the two doc guards (test-docs-bounded.sh and
# test-docs-container-names.sh): seeds a temp skill-shaped directory with one
# known violation per line and asserts each guard reports every violation it
# owns by file:line while letting the clean line through. A guard that stops
# matching (say, a regex edit that no longer sees a tab after `docker`) fails
# here instead of silently passing the real docs. Both guards must also still
# pass against the real skill docs.
#
# Dependencies: sh, awk. No network, no Docker.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BOUNDED="$HERE/test-docs-bounded.sh"
NAMES="$HERE/test-docs-container-names.sh"

tmp="$(mktemp -d)" || exit 1
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
failcount=0

ok()   { pass=$((pass + 1)); }
bad()  { failcount=$((failcount + 1)); echo "FAIL: $1"; }

# The fixture doc: one violation per line (lines 4-8), then a clean line (9).
# Written with printf so the tab on line 6 is explicit.
fix="$tmp/skill"
mkdir -p "$fix/references"
{
  printf '# fixture doc for the doc-guard self-check\n'
  printf '\n'
  printf '```sh\n'
  printf 'docker run --rm cgr.dev/fixture:latest # violation: docker run, one space, unbounded\n'
  printf 'docker  run --rm cgr.dev/fixture:latest # violation: two spaces between docker and run\n'
  printf 'docker\trun --rm cgr.dev/fixture:latest # violation: a tab between docker and run\n'
  printf 'timeout -k 30 60 docker run --name=migr-fixed cgr.dev/fixture:latest # violation: --name=value with a fixed name\n'
  printf 'timeout -k 30 60 docker run --name migr-fixed cgr.dev/fixture:latest # violation: --name value with a fixed name\n'
  printf 'timeout -k 30 60 docker run --name migr-$RUN_ID-probe cgr.dev/fixture:latest # clean: bounded, run-scoped name\n'
  printf '```\n'
} > "$fix/SKILL.md"
printf 'A clean reference page with no docker commands.\n' > "$fix/references/notes.md"

# flags OUT LINENO — succeeds when OUT reports the fixture SKILL.md at LINENO
flags() {
  case "$1" in
    *"SKILL.md:$2:"*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "--- guard 1: bounded-docker guard against the seeded fixture ---"
out=$(sh "$BOUNDED" "$fix" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "bounded guard exited 0 on a fixture with violations: $out"; fi
for n in 4 5 6; do
  if flags "$out" "$n"; then ok; else bad "bounded guard missed the line-$n violation: $out"; fi
done
# Lines 7 and 8 carry the bound; only the names guard owns their violations.
for n in 7 8 9; do
  if flags "$out" "$n"; then bad "bounded guard flagged bounded line $n: $out"; else ok; fi
done

echo "--- guard 2: container-names guard against the seeded fixture ---"
out=$(sh "$NAMES" "$fix" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "names guard exited 0 on a fixture with violations: $out"; fi
for n in 7 8; do
  if flags "$out" "$n"; then ok; else bad "names guard missed the line-$n violation: $out"; fi
done
if flags "$out" 9; then bad "names guard flagged the clean line 9: $out"; else ok; fi

echo "--- both guards against the real skill docs ---"
out=$(sh "$BOUNDED" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "bounded guard fails on the real docs: $out"; fi
out=$(sh "$NAMES" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "names guard fails on the real docs: $out"; fi

echo ""
echo "test-docs-guards-selfcheck: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
