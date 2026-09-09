#!/bin/sh
# run-bounded.sh — run one command under an absolute wall-clock limit and an
# optional idle limit (no new output), killing the command's whole process
# group when either limit fires.
#
# The migration workflow's own docker commands (build, pull, run, save,
# probes) go through this wrapper; the bundled lookup and comparison scripts
# bound their internal docker calls with the timeout utility on their own.
# timeout alone cannot express an idle limit, and the idle limit is what
# catches a build stuck on one step long before the absolute limit is due.
#
# Usage:
#   run-bounded.sh --absolute SECONDS [--idle SECONDS] [--log FILE] -- command [args...]
#
#   --absolute SECONDS  kill the command when this much wall-clock time passes
#   --idle SECONDS      kill the command when this long passes with no new
#                       output (stdout+stderr combined); omit to disable
#   --log FILE          write the command's output to FILE (truncated first)
#                       and leave it there. Without --log, output goes to a
#                       temporary file that is printed to stdout when the
#                       command ends and then removed.
#
# Exit codes:
#   the command's own exit code when it finishes on its own
#   124 — absolute limit fired (matches the timeout utility's convention)
#   125 — idle limit fired
#   2   — usage error
# A fired limit prints one line to stderr naming which limit it was.
#
# docker run special case: killing the docker CLI does not stop its container
# (the container lives daemon-side, and a PID-1 process with no signal
# handler ignores the proxied TERM). When the command is `docker run`, the
# wrapper adds --cidfile so that after a kill it can `docker rm -f` the exact
# container it started; without this, a killed run or probe leaves a
# container running.
#
# Dependencies: sh, kill, sleep, wc, date, mktemp, cat, and setsid
# (util-linux or BusyBox) when present — setsid guarantees the command its
# own process group. Without setsid the script falls back to the shell's job
# control (set -m) and checks the resulting group with ps; if that still does
# not yield a separate group it kills the command process alone rather than
# signal its own group. docker itself is invoked only for the docker run
# cleanup described above.

set -u

# Poll once per second: the limits are tens of seconds to minutes, so a
# 1-second check keeps kill latency far below any limit at no real cost.
POLL=1
# TERM-to-KILL grace of 5 seconds lets a cooperating process (the docker CLI
# included) shut down and report before a stubborn one is killed hard.
GRACE=5

usage() {
  echo "usage: run-bounded.sh --absolute SECONDS [--idle SECONDS] [--log FILE] -- command [args...]" >&2
  exit 2
}

ABSOLUTE=""
IDLE=0
LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --absolute) [ $# -ge 2 ] || usage; ABSOLUTE="$2"; shift 2 ;;
    --idle)     [ $# -ge 2 ] || usage; IDLE="$2"; shift 2 ;;
    --log)      [ $# -ge 2 ] || usage; LOG="$2"; shift 2 ;;
    --)         shift; break ;;
    *)          usage ;;
  esac
done
[ $# -gt 0 ] || usage
case "$ABSOLUTE" in ''|*[!0-9]*) usage ;; esac
[ "$ABSOLUTE" -gt 0 ] || usage
case "$IDLE" in ''|*[!0-9]*) usage ;; esac

TMP_LOG=""
if [ -z "$LOG" ]; then
  TMP_LOG="$(mktemp)" || { echo "run-bounded: cannot create a temp log" >&2; exit 2; }
  LOG="$TMP_LOG"
else
  : > "$LOG" || { echo "run-bounded: cannot write log $LOG" >&2; exit 2; }
fi

pid=""
kill_target=""
cidfile=""

# If the command is `docker run` (no docker global flags in between — the
# workflow's own commands never use any) and does not already pass --cidfile,
# insert one pointing at a fresh path, so remove_container below can address
# the exact container after a kill. docker refuses a cidfile that already
# exists, hence a directory from mktemp -d with the file not yet created.
if [ "${1##*/}" = "docker" ] && [ "${2-}" = "run" ]; then
  has_cidfile=0
  for arg in "$@"; do
    case "$arg" in --cidfile|--cidfile=*) has_cidfile=1 ;; esac
  done
  if [ "$has_cidfile" -eq 0 ]; then
    cid_dir="$(mktemp -d)" || { echo "run-bounded: cannot create a temp dir" >&2; exit 2; }
    cidfile="$cid_dir/cid"
    docker_cmd="$1"
    shift 2
    set -- "$docker_cmd" run --cidfile "$cidfile" "$@"
  fi
fi

# Called only after a kill: remove the container the killed docker run
# client left behind daemon-side. A command that finishes on its own keeps
# its container — a detached `docker run -d` exits immediately and must not
# lose the server it just started.
remove_container() {
  [ -n "$cidfile" ] || return 0
  [ -s "$cidfile" ] && docker rm -f "$(cat "$cidfile")" >/dev/null 2>&1
  discard_cidfile
}

discard_cidfile() {
  [ -n "${cid_dir:-}" ] && rm -rf "$cid_dir"
  cidfile=""
}

# kill_target is the whole process group when the command got its own
# (negative pgid operand), else just the command's pid. TERM first, then
# KILL after the grace for whatever survived.
kill_group() {
  [ -n "$kill_target" ] || return 0
  kill -TERM "$kill_target" 2>/dev/null
  waited=0
  while [ "$waited" -lt "$GRACE" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$kill_target" 2>/dev/null
}

# Without --log the caller still gets the output, just buffered to the end.
finish_log() {
  if [ -n "$TMP_LOG" ]; then
    cat "$TMP_LOG"
    rm -f "$TMP_LOG"
  fi
}

on_signal() {
  [ -n "$pid" ] && kill_group
  remove_container
  finish_log
  echo "run-bounded: interrupted; command killed" >&2
  exit 130
}
trap on_signal INT TERM

# Give the command its own process group so the kill reaches its children.
# setsid is the reliable way: a background child of this non-job-control
# shell is not a group leader, so setsid succeeds in-process and execs —
# the pid is preserved and the new group's id equals it. Fallback: the
# shell's job control (set -m), which some shells refuse without a terminal,
# so the resulting group is verified with ps before any group kill — killing
# our own group would take this script and its caller down with the command.
# stdin comes from /dev/null so a command that reads the terminal fails fast
# instead of stopping on SIGTTIN.
if command -v setsid >/dev/null 2>&1; then
  setsid "$@" > "$LOG" 2>&1 < /dev/null &
  pid=$!
  kill_target="-$pid"
else
  set -m 2>/dev/null
  "$@" > "$LOG" 2>&1 < /dev/null &
  pid=$!
  set +m 2>/dev/null
  my_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  cmd_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$cmd_pgid" ] && [ "$cmd_pgid" != "$my_pgid" ]; then
    kill_target="-$cmd_pgid"
  else
    kill_target="$pid"
  fi
fi

start=$(date +%s)
last_size=0
last_change=$start
reason=""
while kill -0 "$pid" 2>/dev/null; do
  sleep "$POLL"
  now=$(date +%s)
  if [ $((now - start)) -ge "$ABSOLUTE" ]; then
    reason="absolute"
    break
  fi
  if [ "$IDLE" -gt 0 ]; then
    size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -ne "$last_size" ]; then
      last_size=$size
      last_change=$now
    elif [ $((now - last_change)) -ge "$IDLE" ]; then
      reason="idle"
      break
    fi
  fi
done

[ -n "$reason" ] && kill_group
# stderr silenced: some shells report "Terminated"/"Killed" for the reaped
# job here, which reads like an OOM kill; the message below already says
# exactly what happened.
wait "$pid" 2>/dev/null
rc=$?
if [ -n "$reason" ]; then
  remove_container
else
  discard_cidfile
fi
finish_log
case "$reason" in
  absolute)
    echo "run-bounded: absolute limit of ${ABSOLUTE}s exceeded; killed: $*" >&2
    exit 124 ;;
  idle)
    echo "run-bounded: idle limit of ${IDLE}s with no new output exceeded; killed: $*" >&2
    exit 125 ;;
esac
exit "$rc"
