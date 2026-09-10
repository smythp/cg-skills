#!/bin/sh
# Doc guard: every shell line in SKILL.md and references/*.md that invokes a
# long-running docker subcommand (build, pull, run, save, exec, manifest)
# must carry the workflow's inline bound — `timeout -k 30 ` earlier on the
# same line. A doc line an agent copies without a bound is how an unbounded
# build gets back in after review.
#
# What counts as an invocation:
#   - any line inside a ```sh fenced block containing docker <subcommand>
#   - any prose line whose inline code runs docker <subcommand> with
#     arguments; a bare mention closing its backtick right after the
#     subcommand (or one short flag), like `docker run -d` or `docker save`,
#     is descriptive prose, not a command
# Fenced blocks in other languages (the ```markdown report example, the
# ```dockerfile snippets) are skipped. Local-metadata subcommands (inspect,
# history, port, rm, create, cp, export) are exempt: the docs state they need
# no bound, and cleanup lines must run unbounded.
#
# Dependencies: sh, awk. No network, no Docker.

set -u

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0

for f in "$DIR/SKILL.md" "$DIR"/references/*.md; do
  out=$(awk '
    /^```/ {
      if (infence) { infence = 0; skip = 0 }
      else {
        infence = 1
        lang = substr($0, 4)
        gsub(/[ \t]+$/, "", lang)
        skip = (lang != "" && lang != "sh" && lang != "shell" && lang != "bash")
      }
      next
    }
    skip { next }
    {
      line = $0; s = line; base = 0; bad = 0
      while (match(s, /docker (build|pull|run|save|exec|manifest)/)) {
        pre = substr(line, 1, base + RSTART - 1)
        post = substr(line, base + RSTART + RLENGTH)
        if (pre !~ /timeout -k 30 /) {
          bare = (pre ~ /`$/ && post ~ /^( -[A-Za-z]+)?`/)
          if (infence || !bare) bad = 1
        }
        base = base + RSTART + RLENGTH
        s = substr(line, base + 1)
      }
      if (bad) printf "%s:%d: %s\n", FILENAME, FNR, line
    }
  ' "$f")
  if [ -n "$out" ]; then
    echo "$out"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "test-docs-bounded: FAIL — the lines above invoke docker without 'timeout -k 30 ' on the same line"
  exit 1
fi
echo "test-docs-bounded: PASS — every docker build/pull/run/save/exec/manifest line in the docs is bounded"
exit 0
