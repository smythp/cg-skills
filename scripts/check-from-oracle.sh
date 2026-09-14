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
# asks the builder itself, that one reads the whole file.
#
# Usage: check-from-oracle.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]]
#                             [--build-arg NAME=value ...] [--target NAME]
#                             DOCKERFILE CONTEXT
#
# The frontend is evaluated with docker buildx build --call=outline, which
# loads image metadata over the network and executes nothing from the
# Dockerfile. Its progress log prints one line per external base it
# resolves, shaped "#N [internal] load metadata for REF"; those REFs are the
# ones checked. buildx 0.37 drops --platform on --call runs (verified
# against a real build), so the platform travels as explicit --build-arg
# overrides of the automatic platform arguments, which BuildKit applies the
# same way with or without a declaration (also verified). User --build-arg
# values follow the platform pack, so they win, as in docker build.
#
# Exit codes:
#   0 — the outline run succeeded and every resolved reference is allowed
#   1 — a resolved reference is off the allowlist, or the outline run failed
#       or produced output this script cannot parse; a failed or unparsable
#       run is never a pass
#   2 — usage error
#
# Dependencies: sh, grep, sed, sort, tr, docker with buildx (daemon running,
# egress to the registries the file references). The outline call is bounded
# with timeout (or gtimeout, the Homebrew coreutils name on macOS); with
# neither installed it runs unbounded, after one stderr warning.

set -u

usage() {
  echo "usage: check-from-oracle.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]] [--build-arg NAME=value ...] [--target NAME] DOCKERFILE CONTEXT" >&2
  exit 2
}

MIRROR=""
PLATFORM=""
TARGET_STAGE=""
NL='
'
USER_ARGS=""

# normalize_platform VALUE: split VALUE into NORM_OS, NORM_ARCH, NORM_VARIANT
# and apply the normalizations the docker CLI applies before the builder sees
# the platform (the same rules as check-from-lines.sh, each verified against
# a real build). The overrides this script passes bypass that CLI step, so
# skipping this would check a different platform than a real build uses.
normalize_platform() {
  np_val=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$np_val" in
    *,*)
      echo "check-from-oracle.sh: --platform takes one platform per run (got '$1'); a multi-platform build is gated once per platform" >&2
      exit 2
      ;;
  esac
  case "$np_val" in
    */*) : ;;
    *)
      echo "check-from-oracle.sh: --platform must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
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
    echo "check-from-oracle.sh: --platform must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
    exit 2
  fi
  case "$np_rest" in
    */*)
      case "$NORM_VARIANT" in
        ''|*/*)
          echo "check-from-oracle.sh: --platform must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
          exit 2
          ;;
      esac
      ;;
  esac
  case "${NORM_OS}${NORM_ARCH}${NORM_VARIANT}" in
    *[!a-z0-9_.-]*)
      echo "check-from-oracle.sh: --platform must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
      exit 2
      ;;
  esac
  case "$NORM_ARCH" in
    x86_64|x86-64) NORM_ARCH=amd64 ;;
    aarch64) NORM_ARCH=arm64 ;;
    i386) NORM_ARCH=386 ;;
    armhf|armel)
      if [ -n "$NORM_VARIANT" ]; then
        echo "check-from-oracle.sh: --platform does not take a variant with '$NORM_ARCH'; spell the platform as $NORM_OS/arm/vN" >&2
        exit 2
      fi
      if [ "$NORM_ARCH" = armhf ]; then NORM_VARIANT=v7; else NORM_VARIANT=v6; fi
      NORM_ARCH=arm
      ;;
  esac
  if [ "$NORM_ARCH" = arm64 ] && [ "$NORM_VARIANT" = v8 ]; then NORM_VARIANT=""; fi
  if [ "$NORM_ARCH" = arm ] && [ -z "$NORM_VARIANT" ]; then NORM_VARIANT=v7; fi
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
    *) break ;;
  esac
done

DOCKERFILE="${1-}"
CONTEXT="${2-}"
[ -n "$DOCKERFILE" ] && [ -n "$CONTEXT" ] || usage
[ -f "$DOCKERFILE" ] || { echo "check-from-oracle.sh: Dockerfile not found: $DOCKERFILE" >&2; exit 2; }
[ -d "$CONTEXT" ] || { echo "check-from-oracle.sh: context is not a directory: $CONTEXT" >&2; exit 2; }

not_a_pass() {
  echo "check-from-oracle: the outline run could not answer: $1"
  echo "check-from-oracle: this is not a pass; the FROM gate fails."
  exit 1
}

for dep in docker grep sed sort tr; do
  command -v "$dep" >/dev/null 2>&1 || not_a_pass "required command not found: $dep"
done

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

# Build the argument list: the platform pack first, then the user's
# --build-arg values so they override it, then the target. Each TARGET*
# value is overridden individually; BuildKit does not derive the others
# from an overridden TARGETPLATFORM. The BUILD* arguments stay the daemon's
# own platform, which is what a real build on this daemon uses. The values
# in USER_ARGS contain no newlines (checked above), so one line per argument
# is a faithful split; set -f keeps globbing out of the unquoted expansion.
set -f
set --
if [ -n "$PLATFORM" ]; then
  normalize_platform "$PLATFORM"
  set -- --build-arg "TARGETPLATFORM=$NORM_OS/$NORM_ARCH${NORM_VARIANT:+/$NORM_VARIANT}" \
         --build-arg "TARGETOS=$NORM_OS" \
         --build-arg "TARGETARCH=$NORM_ARCH" \
         --build-arg "TARGETVARIANT=$NORM_VARIANT" \
         --build-arg "TARGETOSVERSION="
fi
old_ifs=$IFS
IFS=$NL
for ba in $USER_ARGS; do
  [ -n "$ba" ] && set -- "$@" --build-arg "$ba"
done
IFS=$old_ifs
set +f
[ -n "$TARGET_STAGE" ] && set -- "$@" --target "$TARGET_STAGE"

out=$(bounded docker buildx build --call=outline --progress=plain "$@" \
  -f "$DOCKERFILE" "$CONTEXT" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "check-from-oracle: the outline run failed (exit $rc); its output:"
  printf '%s\n' "$out" | sed 's/^/  | /'
  not_a_pass "BuildKit could not resolve the file for this target and platform"
fi

refs=$(printf '%s\n' "$out" \
  | grep -E '^#[0-9]+ \[internal\] load metadata for ' \
  | sed 's/^#[0-9]* \[internal\] load metadata for //' \
  | sort -u)

# A run that printed metadata lines this script failed to parse must not
# pass; a run with none at all is a file whose reachable stages are scratch
# or aliases only, which is a clean pass.
if [ -z "$refs" ]; then
  if printf '%s' "$out" | grep -q 'load metadata'; then
    printf '%s\n' "$out" | sed 's/^/  | /'
    not_a_pass "the outline output shows metadata loads this script could not parse"
  fi
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
