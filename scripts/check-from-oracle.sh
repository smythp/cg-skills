#!/bin/sh
# check-from-oracle.sh — resolve a Dockerfile with BuildKit's own frontend and
# gate every base image it resolves against the migration allowlist:
# cgr.dev/* (exact host boundary) and the configured external mirror prefix
# (on a / boundary). scratch and stage aliases never appear as metadata
# loads, so they never reach the check.
#
# This covers exactly the stages BuildKit will build for the given target and
# platform; a stage the target does not reach is neither resolved nor built,
# so it is not checked here. check-from-lines.sh covers every FROM line
# textually, reachable or not. The migration gate is both scripts: this one
# asks the builder itself, that one reads the whole file. Both scripts take
# the same options; this one adds the build context operand.
#
# Usage: check-from-oracle.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]]
#                             [--build-platform OS/ARCH[/VARIANT]]
#                             [--build-arg NAME=value ...] [--target NAME]
#                             [--build-context NAME=SOURCE ...]
#                             DOCKERFILE CONTEXT
#
# Named build contexts from the captured invocation pass through to buildx
# unchanged, because BuildKit replaces a FROM whose reference or stage name
# matches a context name; an outline run without them resolves a different
# base than the build. The progress line for an overridden name has the
# form "#N [context NAME] load metadata for REF", which the label-agnostic
# reference parsing below reads like any other load, so REF is checked
# against the allowlist like any base.
#
# The frontend is evaluated with docker buildx build
# --call=outline,format=json, which loads image metadata over the network
# and executes nothing from the Dockerfile. Its progress log prints one line
# per external base it resolves, shaped "#N [LABEL] load metadata for REF".
# Every such line is a reference whatever the bracketed label ([internal],
# [linux/amd64 internal], or any other), and a load-metadata line this
# script cannot parse fails the run naming the line. The run must also show
# positive evidence the outline was performed on the file: the
# load-build-definition step in the progress log and the outline's JSON
# result ("sources") on stdout. The JSON result prints for every file, base
# images or none, where the plain-text outline prints nothing for a file
# whose target stage is unnamed (both verified against real runs). Without
# both markers the run is not a pass, so a docker invocation that succeeded
# without evaluating the file (help output, an unrelated success) cannot
# pass the gate, and a file whose reachable stages have no external base
# (scratch-only, alias-only) passes only with that evidence present.
#
# buildx 0.37 drops --platform on --call runs (verified against a real
# build on this daemon with both the docker driver and a docker-container
# builder, and for --call=targets as well as --call=outline), so the
# platform travels as explicit --build-arg overrides of the
# automatic platform arguments, which BuildKit applies the same way with or
# without a declaration (also verified). With --build-platform the BUILD*
# arguments travel the same way; without it they keep the daemon's own
# platform, which is what a real build on this daemon uses. User --build-arg
# values follow the platform packs, so they win, as in docker build.
#
# The overrides have one precedence difference from a real build. BuildKit
# lets a global ARG that declares a default for an automatic argument name
# beat the automatic value, while a --build-arg beats that default, so an
# override would reverse what the build resolves for such a file. The
# script therefore scans the file before the outline runs and exits 1
# naming the line when a global ARG gives a default to any of the eleven
# automatic argument names (TARGETPLATFORM, TARGETOS, TARGETARCH,
# TARGETVARIANT, TARGETOSVERSION, TARGETSTAGE, BUILDPLATFORM, BUILDOS,
# BUILDARCH, BUILDVARIANT, BUILDOSVERSION); a bare redeclaration such as
# ARG TARGETARCH stays allowed. So the scan can trust its own line
# splitting, a NUL byte anywhere in the file and a CR that is not part of
# a CRLF ending are rejected first, as check-from-lines.sh rejects them.
#
# The Dockerfile and context paths are made absolute and the context is
# passed after --, so a path shaped like an option (a context directory
# named --help) cannot become one.
#
# When EXPERIMENTAL_BUILDKIT_SOURCE_POLICY is set in the environment the run
# fails: a source policy can convert a reference while the log still names
# the original, so the log cannot be read as the list of what the build
# would pull.
#
# Exit codes:
#   0 — the outline run succeeded, showed the evidence above, and every
#       resolved reference is allowed
#   1 — a resolved reference is off the allowlist, or the outline run
#       failed, lacked the evidence, or printed a load-metadata line this
#       script cannot parse, or a source policy is configured in the
#       environment, or the file declares a default for an automatic
#       argument name, or it contains a NUL byte or a bare CR; none of
#       these is a pass
#   2 — usage error
#
# Dependencies: sh, awk, od, grep, sed, sort, tr, docker with buildx
# (daemon running,
# egress to the registries the file references). The outline call is bounded
# with timeout (or gtimeout, the Homebrew coreutils name on macOS); with
# neither installed it runs unbounded, after one stderr warning.

set -u

usage() {
  echo "usage: check-from-oracle.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]] [--build-platform OS/ARCH[/VARIANT]] [--build-arg NAME=value ...] [--target NAME] [--build-context NAME=SOURCE ...] DOCKERFILE CONTEXT" >&2
  exit 2
}

MIRROR=""
PLATFORM=""
BUILD_PLATFORM=""
TARGET_STAGE=""
NL='
'
USER_ARGS=""
BUILD_CONTEXTS=""

# normalize_platform VALUE FLAG: split VALUE into NORM_OS, NORM_ARCH,
# NORM_VARIANT and apply the normalizations the docker CLI applies before
# the builder sees the platform (the same rules as check-from-lines.sh, each
# verified against a real build). The overrides this script passes bypass
# that CLI step, so skipping this would check a different platform than a
# real build uses.
normalize_platform() {
  np_val=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$np_val" in
    *,*)
      echo "check-from-oracle.sh: $2 takes one platform per run (got '$1'); a multi-platform build is gated once per platform" >&2
      exit 2
      ;;
  esac
  case "$np_val" in
    */*) : ;;
    *)
      echo "check-from-oracle.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
      exit 2
      ;;
  esac
  NORM_OS=${np_val%%/*}
  np_rest=${np_val#*/}
  case "$np_rest" in
    */*) NORM_ARCH=${np_rest%%/*}; NORM_VARIANT=${np_rest#*/} ;;
    *)   NORM_ARCH=$np_rest;       NORM_VARIANT="" ;;
  esac
  if [ -z "$NORM_OS" ] || [ -z "$NORM_ARCH" ]; then
    echo "check-from-oracle.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
    exit 2
  fi
  case "$np_rest" in
    */*)
      case "$NORM_VARIANT" in
        ''|*/*)
          echo "check-from-oracle.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
          exit 2
          ;;
      esac
      ;;
  esac
  case "${NORM_OS}${NORM_ARCH}${NORM_VARIANT}" in
    *[!a-z0-9_.-]*)
      echo "check-from-oracle.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
      exit 2
      ;;
  esac
  # Arch aliases and variant rules, matching containerd platforms.Normalize,
  # which is what the docker CLI applies. Each rule is pinned by a real
  # build in test-check-from-lines.sh (the two scripts share this function).
  # x86_64 and x86-64 become amd64, aarch64 becomes arm64, i386 becomes 386
  # and drops any variant, armhf becomes arm/v7 and armel arm/v6 replacing
  # any variant; then amd64 drops a v1 variant, arm64 drops an 8 or v8
  # variant, and arm maps no variant and 7 to v7 and 5, 6, 8 to v5, v6, v8.
  # Every other variant passes through unchanged (amd64/v2, arm64/v9, and
  # arm/v8 keep theirs).
  case "$NORM_ARCH" in
    x86_64|x86-64) NORM_ARCH=amd64 ;;
    aarch64) NORM_ARCH=arm64 ;;
    i386) NORM_ARCH=386; NORM_VARIANT="" ;;
    armhf) NORM_ARCH=arm; NORM_VARIANT=v7 ;;
    armel) NORM_ARCH=arm; NORM_VARIANT=v6 ;;
  esac
  case "$NORM_ARCH" in
    amd64) case "$NORM_VARIANT" in v1) NORM_VARIANT="" ;; esac ;;
    arm64) case "$NORM_VARIANT" in 8|v8) NORM_VARIANT="" ;; esac ;;
    arm)
      case "$NORM_VARIANT" in
        ''|7) NORM_VARIANT=v7 ;;
        5|6|8) NORM_VARIANT="v$NORM_VARIANT" ;;
      esac
      ;;
  esac
}
while :; do
  case "${1-}" in
    --mirror)
      MIRROR="${2-}"
      [ -n "$MIRROR" ] || { echo "check-from-oracle.sh: --mirror needs a value" >&2; exit 2; }
      shift 2
      ;;
    --platform)
      PLATFORM="${2-}"
      [ -n "$PLATFORM" ] || { echo "check-from-oracle.sh: --platform needs a value" >&2; exit 2; }
      shift 2
      ;;
    --build-platform)
      BUILD_PLATFORM="${2-}"
      [ -n "$BUILD_PLATFORM" ] || { echo "check-from-oracle.sh: --build-platform needs a value" >&2; exit 2; }
      shift 2
      ;;
    --build-arg)
      ba="${2-}"
      case "$ba" in
        ''|=*) echo "check-from-oracle.sh: --build-arg needs NAME=value" >&2; exit 2 ;;
        *=*) : ;;
        *) echo "check-from-oracle.sh: --build-arg needs NAME=value, got '$ba'" >&2; exit 2 ;;
      esac
      case "$ba" in
        *"$NL"*) echo "check-from-oracle.sh: a --build-arg value must not contain a newline" >&2; exit 2 ;;
      esac
      USER_ARGS="${USER_ARGS}${ba}${NL}"
      shift 2
      ;;
    --target)
      TARGET_STAGE="${2-}"
      case "$TARGET_STAGE" in
        ''|*[!A-Za-z0-9_.-]*)
          echo "check-from-oracle.sh: --target needs a stage name (letters, digits, _ . -)" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --build-context)
      bc="${2-}"
      case "$bc" in
        ''|=*) echo "check-from-oracle.sh: --build-context needs NAME=SOURCE" >&2; exit 2 ;;
        *=*) : ;;
        *) echo "check-from-oracle.sh: --build-context needs NAME=SOURCE, got '$bc'" >&2; exit 2 ;;
      esac
      case "$bc" in
        *"$NL"*) echo "check-from-oracle.sh: a --build-context value must not contain a newline" >&2; exit 2 ;;
      esac
      BUILD_CONTEXTS="${BUILD_CONTEXTS}${bc}${NL}"
      shift 2
      ;;
    *) break ;;
  esac
done

DOCKERFILE="${1-}"
CONTEXT="${2-}"
[ -n "$DOCKERFILE" ] && [ -n "$CONTEXT" ] || usage
[ -f "$DOCKERFILE" ] || { echo "check-from-oracle.sh: Dockerfile not found: $DOCKERFILE" >&2; exit 2; }
[ -d "$CONTEXT" ] || { echo "check-from-oracle.sh: context is not a directory: $CONTEXT" >&2; exit 2; }
if [ -n "$BUILD_PLATFORM" ] && [ -z "$PLATFORM" ]; then
  echo "check-from-oracle.sh: --build-platform needs --platform as well" >&2
  exit 2
fi

# Absolute paths, so a path shaped like an option stays a path; the context
# is additionally passed after -- below.
case "$DOCKERFILE" in /*) : ;; *) DOCKERFILE="$PWD/$DOCKERFILE" ;; esac
case "$CONTEXT" in /*) : ;; *) CONTEXT="$PWD/$CONTEXT" ;; esac

not_a_pass() {
  echo "check-from-oracle: the outline run could not answer: $1"
  echo "check-from-oracle: this is not a pass; the FROM gate fails."
  exit 1
}

for dep in docker awk od grep sed sort tr; do
  command -v "$dep" >/dev/null 2>&1 || not_a_pass "required command not found: $dep"
done

# A source policy rewrites references after the progress log names the
# original, so the log stops being evidence of what the build pulls. Refuse
# to answer rather than read a log that may not match the build.
if [ "${EXPERIMENTAL_BUILDKIT_SOURCE_POLICY+set}" = set ]; then
  not_a_pass "EXPERIMENTAL_BUILDKIT_SOURCE_POLICY is set in the environment; a source policy can convert a reference while the log names the original. Unset it and run the gate again"
fi

# The declared-default scan below reads the file line by line, so it needs
# the same physical-line guarantee as check-from-lines.sh. A NUL byte
# anywhere, or a CR that is not immediately followed by LF, is rejected
# naming the line; BuildKit keeps both bytes inside the surrounding line
# where a line-based scan would split it, and awk implementations disagree
# about NUL bytes in input. CRLF endings are accepted.
BAD_BYTE=$(od -An -v -t o1 < "$DOCKERFILE" | LC_ALL=C awk '
  {
    for (i = 1; i <= NF; i++) {
      if (pcr && $i != "012") { print "CR " nl + 1; found = 1; exit }
      if ($i == "000") { print "NUL " nl + 1; found = 1; exit }
      pcr = ($i == "015")
      if ($i == "012") nl++
    }
  }
  END { if (!found && pcr) print "CR " nl + 1 }
')
if [ -n "$BAD_BYTE" ]; then
  case "$BAD_BYTE" in
    NUL*) not_a_pass "line ${BAD_BYTE#* } of $DOCKERFILE contains a NUL byte; this script cannot scan such a file the way BuildKit reads it" ;;
    *)    not_a_pass "line ${BAD_BYTE#* } of $DOCKERFILE contains a CR that is not part of a CRLF line ending; this script cannot scan such a file the way BuildKit reads it (CRLF endings are accepted)" ;;
  esac
fi

# A global ARG that declares a default for an automatic argument name would
# resolve differently under this script's overrides than under a real
# build (the header says why), so the file is rejected before the outline
# runs. The scan mirrors check-from-lines.sh's line assembly (BOM, the
# escape directive, comments and blank lines inside continuations) and
# stops at the first FROM; a bare redeclaration has no = and passes. An
# escape character inside an ARG token is rejected rather than decoded,
# as the textual gate rejects it, so an escape cannot hide a name from
# this scan.
ARG_SCAN=$(LC_ALL=C awk '
function fail(msg) { print msg; FOUND = 1; exit }
BEGIN {
  BOM = sprintf("%c%c%c", 239, 187, 191)
  WS  = sprintf("[ \t\r%c%c]+", 11, 12)
  ESC = "\\"
  directive_mode = 1
  buf = ""; bufline = 0
  n_auto = split("TARGETPLATFORM TARGETOS TARGETARCH TARGETVARIANT TARGETOSVERSION TARGETSTAGE BUILDPLATFORM BUILDOS BUILDARCH BUILDVARIANT BUILDOSVERSION", auto_names, " ")
  for (b = 1; b <= n_auto; b++) AUTO[auto_names[b]] = 1
}
{
  raw = $0
  if (NR == 1 && substr(raw, 1, 3) == BOM) raw = substr(raw, 4)
  line = raw
  sub(/\r$/, "", line); sub(/[ \t]+$/, "", line)
  trimmed = line
  sub("^" WS, "", trimmed)
  if (directive_mode) {
    if (trimmed ~ /^#[ \t]*[A-Za-z][A-Za-z0-9]*[ \t]*=[ \t]*[^ \t]/) {
      dkey = trimmed
      sub(/^#[ \t]*/, "", dkey)
      dval = dkey
      sub(/[ \t]*=.*$/, "", dkey)
      dkey = tolower(dkey)
      sub(/^[A-Za-z][A-Za-z0-9]*[ \t]*=[ \t]*/, "", dval)
      sub(/[ \t]+$/, "", dval)
      if (dkey == "escape" || dkey == "syntax" || dkey == "check") {
        if (dkey == "escape" && dval == "`") ESC = "`"
        next
      }
      directive_mode = 0
    } else {
      directive_mode = 0
    }
  }
  if (trimmed ~ /^#/) next
  if (trimmed == "") next
  if (buf == "") bufline = NR
  llen = length(line)
  if (substr(line, llen, 1) == ESC && (llen == 1 || substr(line, llen - 1, 1) != ESC)) {
    buf = buf substr(line, 1, llen - 1)
    next
  }
  buf = buf line
  logical = buf; buf = ""
  sub("^" WS, "", logical)
  n = split(logical, f, WS)
  if (n == 0) next
  instr = toupper(f[1])
  if (instr == "FROM") exit
  if (instr != "ARG") next
  for (ai = 2; ai <= n; ai++) {
    t = f[ai]
    if (index(t, ESC) > 0)
      fail("line " bufline " has an ARG token containing the escape character; this script cannot tell what name it declares, so the file is rejected rather than guessed at")
    p = index(t, "=")
    if (p <= 1) continue
    name = substr(t, 1, p - 1)
    if (name in AUTO)
      fail("line " bufline " declares a default for the automatic argument " name ". BuildKit lets that default beat the automatic value while a --build-arg beats the default, and this script can pass the platform only as --build-arg overrides, so the outline would resolve a different file than the build. Redeclare it bare (ARG " name ") or use another name")
  }
}
' < "$DOCKERFILE")
if [ -n "$ARG_SCAN" ]; then
  not_a_pass "$ARG_SCAN"
fi

# 10-minute bound on the outline call. TIMEOUT_BIN is timeout if present,
# else gtimeout (Homebrew coreutils on macOS installs it under that name),
# else empty; with neither, the call runs unbounded after the warning below.
TIME_LIMIT=600
KILL_GRACE=30
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
else TIMEOUT_BIN=""
fi
bounded() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k "$KILL_GRACE" "$TIME_LIMIT" "$@"
  else
    "$@"
  fi
}
[ -n "$TIMEOUT_BIN" ] || echo "check-from-oracle: no timeout binary found; the outline call runs without a time bound" >&2

# Build the argument list: the platform packs first, then the user's
# --build-arg values so they override them, then the target. Each TARGET*
# and BUILD* value is overridden individually; BuildKit does not derive the
# others from an overridden TARGETPLATFORM. Without --build-platform the
# BUILD* arguments stay the daemon's own platform, which is what a real
# build on this daemon uses. The values in USER_ARGS contain no newlines
# (checked above), so one line per argument is a faithful split; set -f
# keeps globbing out of the unquoted expansion.
set -f
set --
if [ -n "$PLATFORM" ]; then
  normalize_platform "$PLATFORM" --platform
  set -- --build-arg "TARGETPLATFORM=$NORM_OS/$NORM_ARCH${NORM_VARIANT:+/$NORM_VARIANT}" \
         --build-arg "TARGETOS=$NORM_OS" \
         --build-arg "TARGETARCH=$NORM_ARCH" \
         --build-arg "TARGETVARIANT=$NORM_VARIANT" \
         --build-arg "TARGETOSVERSION="
fi
if [ -n "$BUILD_PLATFORM" ]; then
  normalize_platform "$BUILD_PLATFORM" --build-platform
  set -- "$@" \
         --build-arg "BUILDPLATFORM=$NORM_OS/$NORM_ARCH${NORM_VARIANT:+/$NORM_VARIANT}" \
         --build-arg "BUILDOS=$NORM_OS" \
         --build-arg "BUILDARCH=$NORM_ARCH" \
         --build-arg "BUILDVARIANT=$NORM_VARIANT" \
         --build-arg "BUILDOSVERSION="
fi
old_ifs=$IFS
IFS=$NL
for ba in $USER_ARGS; do
  [ -n "$ba" ] && set -- "$@" --build-arg "$ba"
done
# Named contexts pass through unchanged (their values contain no newlines,
# checked at the option); buildx applies the last value per name, and it
# refuses a name that is not a valid reference, which fails the run.
for bc in $BUILD_CONTEXTS; do
  [ -n "$bc" ] && set -- "$@" --build-context "$bc"
done
IFS=$old_ifs
set +f
[ -n "$TARGET_STAGE" ] && set -- "$@" --target "$TARGET_STAGE"

out=$(bounded docker buildx build --call=outline,format=json --progress=plain "$@" \
  -f "$DOCKERFILE" -- "$CONTEXT" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "check-from-oracle: the outline run failed (exit $rc); its output:"
  printf '%s\n' "$out" | sed 's/^/  | /'
  not_a_pass "BuildKit could not resolve the file for this target and platform"
fi

# Positive evidence the outline was performed on this file: the progress
# log's load-build-definition step and the JSON outline result on stdout.
# A docker run that succeeded without both (help output, an unrelated
# success, an empty run) is treated as not performed, never as a pass.
if ! printf '%s\n' "$out" | grep -q '^#[0-9][0-9]* \[[^][]*\] load build definition from '; then
  printf '%s\n' "$out" | sed 's/^/  | /'
  not_a_pass "the output shows no load-build-definition step, so there is no evidence the outline ran on $DOCKERFILE"
fi
if ! printf '%s\n' "$out" | grep -q '"sources"'; then
  printf '%s\n' "$out" | sed 's/^/  | /'
  not_a_pass "the output has no outline JSON result (\"sources\"), so there is no evidence the outline completed"
fi

# Every line containing "load metadata for" is a reference, whatever its
# bracketed step label; a line whose shape this script cannot parse fails
# the run naming the line. With the evidence above, a run with no metadata
# lines at all is a file whose reachable stages are scratch or aliases
# only, which is a clean pass.
meta=$(printf '%s\n' "$out" | grep -F 'load metadata for')
refs=""
if [ -n "$meta" ]; then
  bad=$(printf '%s\n' "$meta" | grep -vE '^#[0-9]+ \[[^][]+\] load metadata for [^ ]+$')
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | sed 's/^/  | /'
    not_a_pass "these load-metadata lines do not have the shape this script can parse, so the references cannot be checked"
  fi
  refs=$(printf '%s\n' "$meta" \
    | sed 's/^#[0-9]* \[[^][]*\] load metadata for //' \
    | sort -u)
fi

if [ -z "$refs" ]; then
  echo "check-from-oracle: OK — the reachable stages of $DOCKERFILE resolve no external base images"
  exit 0
fi

mirror=$(printf '%s' "$MIRROR" | tr '[:upper:]' '[:lower:]' | sed 's:/*$::; s/^[ 	]*//; s/[ 	]*$//')

fail=0
for ref in $refs; do
  lc=$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')
  allowed=0
  case "$lc" in
    cgr.dev/*) allowed=1 ;;
  esac
  if [ "$allowed" -eq 0 ] && [ -n "$mirror" ]; then
    case "$lc" in
      "$mirror"/*) allowed=1 ;;
    esac
  fi
  if [ "$allowed" -eq 1 ]; then
    echo "check-from-oracle: allowed  $ref"
  else
    echo "check-from-oracle: REJECTED $ref — not on cgr.dev/* or the configured external mirror"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check-from-oracle: BuildKit resolves at least one base image off the allowlist for this target and platform"
  exit 1
fi
echo "check-from-oracle: OK — every base image BuildKit resolves for $DOCKERFILE is on the allowlist"
exit 0
