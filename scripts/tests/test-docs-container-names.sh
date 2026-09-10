#!/bin/sh
# Doc guard: every container name assigned in SKILL.md and references/*.md —
# `--name ` followed by a value — must use the run identifier: the value
# starts with `migr-$RUN_ID-`. A fixed literal name collides across
# concurrent runs, and one run's cleanup then removes the other run's
# container.
#
# Prose references to the flag itself, like "gets a `--name`", have no value
# after them (no trailing space before the closing backtick) and are ignored.
#
# Dependencies: sh, awk. No network, no Docker.

set -u

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0

for f in "$DIR/SKILL.md" "$DIR"/references/*.md; do
  out=$(awk '
    {
      s = $0; bad = 0
      while ((i = index(s, "--name ")) > 0) {
        after = substr(s, i + 7)
        if (substr(after, 1, 13) != "migr-$RUN_ID-") bad = 1
        s = after
      }
      if (bad) printf "%s:%d: %s\n", FILENAME, FNR, $0
    }
  ' "$f")
  if [ -n "$out" ]; then
    echo "$out"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "test-docs-container-names: FAIL — the container names above do not start with migr-\$RUN_ID-"
  exit 1
fi
echo "test-docs-container-names: PASS — every --name in the docs uses migr-\$RUN_ID-"
exit 0
