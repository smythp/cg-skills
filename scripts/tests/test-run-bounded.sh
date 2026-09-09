#!/bin/sh
# Fixture tests for run-bounded.sh. No Docker needed; every fixture is plain
# sh with limits of a few seconds so the suite stays fast.
#
# Covers:
#   1. a command that finishes normally propagates its exit code (0 and 3)
#      and its output reaches stdout without --log
#   2. a stalled command (sleep, no output) is killed by the idle limit
#      (exit 125, message names the idle limit, well before the sleep ends)
#   3. a chatty command that runs long is killed by the absolute limit
#      (exit 124, message names the absolute limit)
#   4. usage errors exit 2
#   5. --log captures the output in the named file
#   6. a killed `docker run` gets --cidfile injected and its container
#      removed with docker rm -f, proven with a docker shim on PATH so the
#      suite still needs no real Docker

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/run-bounded.sh"

pass=0
failcount=0

ok()  { pass=$((pass + 1)); }
bad() { failcount=$((failcount + 1)); echo "FAIL: $1"; }

echo "--- case 1: normal completion propagates the exit code ---"
out=$(sh "$SCRIPT" --absolute 10 -- sh -c 'echo done-marker; exit 0' 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "clean command: expected rc 0, got $rc"; fi
case "$out" in
  *done-marker*) ok ;;
  *) bad "clean command: stdout not delivered without --log, got: $out" ;;
esac
sh "$SCRIPT" --absolute 10 -- sh -c 'exit 3' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then ok; else bad "failing command: expected rc 3, got $rc"; fi

echo "--- case 2: stalled command killed by the idle limit ---"
start=$(date +%s)
out=$(sh "$SCRIPT" --absolute 60 --idle 2 -- sleep 30 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
if [ "$rc" -eq 125 ]; then ok; else bad "idle kill: expected rc 125, got $rc"; fi
case "$out" in
  *"idle limit"*) ok ;;
  *) bad "idle kill: message must name the idle limit, got: $out" ;;
esac
# The sleep runs 30s untouched; anything under 15s proves the kill fired.
if [ "$elapsed" -lt 15 ]; then ok; else bad "idle kill: took ${elapsed}s; the stalled command was not killed early"; fi

echo "--- case 3: chatty long-runner killed by the absolute limit ---"
start=$(date +%s)
out=$(sh "$SCRIPT" --absolute 3 --idle 60 -- sh -c 'while :; do echo tick; sleep 1; done' 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
if [ "$rc" -eq 124 ]; then ok; else bad "absolute kill: expected rc 124, got $rc"; fi
case "$out" in
  *"absolute limit"*) ok ;;
  *) bad "absolute kill: message must name the absolute limit, got: $out" ;;
esac
# The loop never ends on its own; anything under 15s proves the kill fired.
if [ "$elapsed" -lt 15 ]; then ok; else bad "absolute kill: took ${elapsed}s; the loop was not killed"; fi

echo "--- case 4: usage errors exit 2 ---"
sh "$SCRIPT" -- sleep 1 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "missing --absolute: expected rc 2, got $rc"; fi
sh "$SCRIPT" --absolute 5 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "missing command: expected rc 2, got $rc"; fi
sh "$SCRIPT" --absolute nope -- true >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok; else bad "non-numeric --absolute: expected rc 2, got $rc"; fi

echo "--- case 5: --log captures the output ---"
log="$(mktemp)" || exit 1
sh "$SCRIPT" --absolute 10 --log "$log" -- sh -c 'echo into-the-log' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "--log run: expected rc 0, got $rc"; fi
case "$(cat "$log")" in
  *into-the-log*) ok ;;
  *) bad "--log: output missing from the log file" ;;
esac
rm -f "$log"

echo "--- case 6: killed docker run cleans up its container (shim) ---"
# The shim stands in for docker: `run` writes a fake container id into the
# injected --cidfile and stalls ignoring TERM (like a container whose PID 1
# has no handler); every call is appended to a log so the post-kill
# `docker rm -f <id>` is observable.
shimdir="$(mktemp -d)" || exit 1
calls="$shimdir/calls.log"
cat > "$shimdir/docker" <<'SHIM'
#!/bin/sh
echo "docker $*" >> "${DOCKER_SHIM_LOG:?}"
if [ "$1" = "run" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--cidfile" ] && echo fakecid123 > "$a"
    prev="$a"
  done
  trap '' TERM
  sleep 30
fi
exit 0
SHIM
chmod +x "$shimdir/docker"
DOCKER_SHIM_LOG="$calls" PATH="$shimdir:$PATH" \
  sh "$SCRIPT" --absolute 30 --idle 2 -- docker run --rm fake-image sleep 60 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 125 ]; then ok; else bad "docker shim: expected idle-kill rc 125, got $rc"; fi
if grep -q '^docker run --cidfile ' "$calls"; then ok; else bad "docker shim: --cidfile was not injected into docker run"; fi
if grep -q '^docker rm -f fakecid123$' "$calls"; then ok; else bad "docker shim: the killed run's container was not removed (no docker rm -f)"; fi
rm -rf "$shimdir"

echo ""
echo "test-run-bounded: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
