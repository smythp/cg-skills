#!/bin/sh
# Doc guard: every container name assigned in SKILL.md and references/*.md —
# `--name value` (one or more spaces or tabs before the value) or
# `--name=value` — must use the run identifier: the value starts with
# `migr-$RUN_ID-`. A fixed literal name collides across concurrent runs, and
# one run's cleanup then removes the other run's container.
#
# Prose references to the flag itself, like "gets a `--name`", have neither
# `=` nor whitespace-then-value after them and are ignored.
#
# An optional first argument points the guard at another directory laid out
# like the skill (SKILL.md plus references/) — the self-check uses this;
# default is this skill's own docs.
#
# Dependencies: sh, awk. No network, no Docker.

set -u

DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
fail=0

for f in "$DIR/SKILL.md" "$DIR"/references/*.md; do
  out=$(awk '
    {
      s = $0; bad = 0
      while (match(s, /--name(=|[ \t]+)/)) {
        val = substr(s, RSTART + RLENGTH)
        if (substr(val, 1, 13) != "migr-$RUN_ID-") bad = 1
        s = val
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
