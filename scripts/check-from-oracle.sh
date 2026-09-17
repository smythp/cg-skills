#!/bin/sh
# check-from-oracle.sh — take the stage graph from BuildKit's own frontend
# and gate every base image in it against the migration allowlist:
# cgr.dev/* (exact host boundary) and the configured external mirror prefix
# (on a / boundary).
#
# Posture. The FROM gate exists to catch mistakes in a migration. It is
# not a guarantee that a Dockerfile written to defeat it cannot pass, and
# it does not try to lock down every rare way to specify an image. This
# script is the deciding half of the gate:
# check-from-lines.sh reads the file textually and advises, with
# UNVERIFIED lines for the constructs it cannot verify, and this script
# asks BuildKit itself what the file resolves. It exits 1 in two cases
# only. REJECTED means a base is known to resolve outside the allowlist,
# from the stage graph BuildKit reports or through a named build context.
# Everything else that exits 1 is the script refusing to answer on its own
# account, printed as not a pass: BuildKit gave no answer (a failed call, a
# pinned frontend without subrequest support), the answer lacks its
# positive evidence, a load-metadata line does not parse, a source policy
# in the environment can rewrite references behind the log, a base cannot
# be expanded or serialized with certainty (a NUL byte or lone CR in the
# file breaks the line-based expansion scan the same way), or a resolved
# load sits outside the FROM set in a file with no artifact-capable
# instruction, the unexpanded-base fallback that catches any divergence
# between the scan and the frontend.
#
# The FROM set comes from docker buildx build --call=targets,format=json,
# which returns every stage with its base exactly as written, from
# BuildKit's own parse of the file. Each base is then expanded with the
# same rules check-from-lines.sh applies (global ARGs with the user's
# --build-arg overrides, the :- and :+ modifiers, the automatic platform
# arguments as seeded, single-quoted defaults literal), substituted through
# the named build contexts, and checked against the allowlist. A base that
# is a stage name is a stage reference, not a pull (BuildKit resolves
# stage names anywhere in the file, forward references included, verified
# against a real run), and scratch is the empty base. A base this script
# cannot expand with certainty, and a targets call that fails or shows no
# evidence it ran, exit 1.
#
# Every other reference the build resolves (COPY --from=IMAGE, a RUN
# --mount=from=IMAGE, ADD from an image) is an external artifact source,
# not a base: references/from-and-registry-rules.md permits artifact
# copies and asks the report to name them. The outline run below surfaces
# them; each one is printed as a WARNING naming the linkage reason (a
# binary copied from another distribution links against that
# distribution's libraries) and allowed. A
# reference that is both a FROM base and an artifact source is in the FROM
# set, so it is checked as a base; the artifact allowance cannot launder a
# base. The artifact report has a guard: a load outside the FROM set is
# reported as an artifact source only when the file contains at least one
# instruction that can pull an image other than FROM (a COPY --from= or a
# RUN --mount= with a from= source, counted on the joined logical lines;
# a source that names a declared stage does not count, because a stage
# cannot pull an image, mount keys match case-insensitively as BuildKit
# matches them, and quotes in a mount value are read the way BuildKit's
# flag parsing reads them). With none present, such a load can only be a
# base the scan expanded differently than the frontend did, and the run
# exits 1 naming it. That
# guard is the fallback for any divergence between the scan and the
# frontend: whatever the scan misreads, the extra load fails the gate
# instead of passing as an artifact source.
#
# This gate covers every stage the file declares, like the textual gate.
# The migration gate is both scripts: this one asks the builder for the
# stage graph and the resolved references, that one reads the whole file
# textually. Both scripts take the same options; this one adds the build
# context operand.
#
# Usage: check-from-oracle.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]]
#                             [--build-platform OS/ARCH[/VARIANT]]
#                             [--build-arg NAME=value ...] [--target NAME]
#                             [--build-context NAME=SOURCE ...]
#                             DOCKERFILE CONTEXT
#
# Named build contexts from the captured invocation pass through to buildx
# unchanged, and the FROM set applies them the way BuildKit does: a context
# name matches the expanded base or a stage name after docker reference
# normalization on both sides (the registry host compares byte-exact with
# its case preserved), a name matching a stage's AS name applies at the
# stage's definition and replaces that stage's base even when no FROM
# references the name, a docker-image://REF source replaces the base with
# REF for the check, and any other source kind matching a base or a stage
# name exits 1, because a base built from a directory, git repository, oci
# layout, or another target cannot be checked against a registry
# allowlist. A context that matches no base is left to the artifact rule.
# The progress line for an overridden name has the form
# "#N [context NAME] load metadata for REF", which the label-agnostic
# reference parsing below reads like any other load.
#
# After the FROM set passes, the file is evaluated with docker buildx build
# --call=outline,format=json, which loads image metadata over the network
# and executes nothing from the Dockerfile. Its progress log prints one line
# per external reference it resolves, shaped "#N [LABEL] load metadata for
# REF", whatever the bracketed label ([internal], [linux/amd64 internal],
# [context NAME], or any other); a load-metadata line this
# script cannot parse fails the run naming the line. A load matching the
# FROM set (as written or in canonical form, with docker.io/library/ and
# :latest filled in) is a base already checked above; every other load is
# printed as an external artifact source. Both calls must show positive
# evidence they ran on the file: the load-build-definition step in the
# progress log, plus the JSON result on stdout ("targets" for the first
# call, "sources" for the second; the JSON prints for every file, named
# target stage or not, verified against real runs). Without the evidence
# the run is not a pass, so a docker invocation that succeeded without
# evaluating the file (help output, an unrelated success) cannot pass the
# gate, and a file with no external base (scratch-only, alias-only) passes
# only with that evidence present.
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
# The overrides are precedence-faithful to a real build. BuildKit lets a
# global ARG that declares a default for an automatic argument name beat
# the automatic value, while a --build-arg beats that default (each pinned
# with real cacheonly builds on 2026-09-17, TARGETSTAGE against --target
# included), so for every automatic name the file gives a declared global
# default, the pre-scan below omits that name's synthetic override and
# BuildKit applies the declared default exactly as the real build does; the
# expansion scan applies the same precedence when it seeds its own table. A
# bare redeclaration such as ARG TARGETARCH is not a default and changes
# nothing. So the scan can trust its own line
# splitting, a NUL byte anywhere in the file and a CR that is not part of
# a CRLF ending are rejected first, as line-based scans require.
# The scan reads the parser directives the way check-from-lines.sh does,
# VT and FF normalized to spaces inside a directive line. A syntax
# directive pinning a frontend other than the rolling docker/dockerfile:1
# tag runs: BuildKit resolves the file under the pinned frontend (verified
# with docker/dockerfile:1.6, which answers both calls itself, and 1.4.0,
# whose subrequests buildx serviced through docker/dockerfile:1.8.1 pulled
# by digest, both on 2026-09-17), and one WARNING says the textual
# expansion assumes the rolling syntax while BuildKit resolves under the
# pin. A pinned frontend without subrequest support fails both calls with
# unsupported frontend capability moby.buildkit.frontend.subrequests
# (verified with docker/dockerfile:1.0); the run is then not a pass, with a
# message that the frontend lacks the outline call and that switching the
# directive to docker/dockerfile:1 lets the gate run.
#
# For the expansion, TARGETSTAGE is seeded from --target when given and a
# base that reads it without one exits 1 asking for --target, and without
# --build-platform the BUILD* values take the target platform, matching
# check-from-lines.sh's documented deviation for a cross-platform build.
# The outline call itself keeps the daemon's BUILD* values in that case,
# which is what a real build on this daemon uses, so on a cross-platform
# build the caller passes --build-platform, as step 9 instructs, and the
# FROM set and the build then read the same values.
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
#   0 — both calls succeeded with their evidence, every base in the FROM
#       set is on the allowlist, and every other resolved reference was
#       printed as an external artifact source WARNING
#   1 — a base is off the allowlist (REJECTED), or the script refuses to
#       answer on its own account: a base could not be expanded or
#       classified with certainty, a base is overridden by a context
#       that is not a docker-image:// reference, either call failed
#       (a pinned frontend without subrequest support included), lacked
#       its evidence, or printed a load-metadata line this script
#       cannot parse, a source policy is configured in the environment,
#       the file contains a NUL byte or a bare CR, or a resolved load
#       sits outside the FROM set in a file with no artifact-capable
#       instruction; none of these is a pass
#   2 — usage error
#
# Dependencies: sh, awk, od, grep, sed, sort, tr, docker with buildx
# (daemon running,
# egress to the registries the file references). Each buildx call is bounded
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

# The expansion scan below reads the file line by line, so it needs
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

# The expansion scan implements the rolling docker/dockerfile:1 frontend's
# parsing rules. A syntax directive naming any other frontend still runs,
# because BuildKit resolves the file under the pinned frontend and its
# answer is the gate; this pre-scan only reads the pin so the run can say
# so in one WARNING, and so a call that fails on a frontend without
# subrequest support can name the pin. The walk mirrors the directive
# block of the main scan: consecutive directive lines from the top of the
# file, a BOM and leading whitespace allowed, VT and FF normalized to
# spaces before the match, the block ended by the first line that is not a
# known directive.
SYN_PIN=$(LC_ALL=C awk '
BEGIN {
  BOM = sprintf("%c%c%c", 239, 187, 191)
  WS  = sprintf("[ \t\r%c%c]+", 11, 12)
  CTRL_WS = sprintf("[%c%c\r]", 11, 12)
}
{
  raw = $0
  if (NR == 1 && substr(raw, 1, 3) == BOM) raw = substr(raw, 4)
  line = raw
  sub(/\r$/, "", line); sub(/[ \t]+$/, "", line)
  trimmed = line
  sub("^" WS, "", trimmed)
  dline = trimmed
  gsub(CTRL_WS, " ", dline)
  if (dline !~ /^#[ \t]*[A-Za-z][A-Za-z0-9]*[ \t]*=[ \t]*[^ \t]/) exit 0
  dkey = dline
  sub(/^#[ \t]*/, "", dkey)
  dval = dkey
  sub(/[ \t]*=.*$/, "", dkey)
  dkey = tolower(dkey)
  sub(/^[A-Za-z][A-Za-z0-9]*[ \t]*=[ \t]*/, "", dval)
  sub(/[ \t]+$/, "", dval)
  if (dkey != "escape" && dkey != "syntax" && dkey != "check") exit 0
  if (dkey == "syntax" && dval != "docker/dockerfile:1" && dval != "docker.io/docker/dockerfile:1") {
    print dval
    exit 0
  }
}
' < "$DOCKERFILE")
if [ -n "$SYN_PIN" ]; then
  echo "check-from-oracle: WARNING: the syntax directive pins the frontend $SYN_PIN; the textual expansion in this script assumes the rolling docker/dockerfile:1 syntax, and BuildKit is resolving the file under the pinned frontend"
fi

# When both buildx calls fail because the pinned frontend cannot answer
# subrequests, this names the pin and the way out.
pinned_frontend_check() {
  if [ -n "$SYN_PIN" ] && printf '%s\n' "$1" | grep -q 'unsupported frontend capability moby.buildkit.frontend.subrequests'; then
    not_a_pass "the pinned frontend $SYN_PIN does not support the outline call (unsupported frontend capability moby.buildkit.frontend.subrequests), so BuildKit cannot answer for this file; switching the directive to docker/dockerfile:1 lets the gate run"
  fi
}

# 10-minute bound on each buildx call. TIMEOUT_BIN is timeout if present,
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
[ -n "$TIMEOUT_BIN" ] || echo "check-from-oracle: no timeout binary found; the buildx calls run without a time bound" >&2

# Global ARG defaults for the automatic argument names, read before the
# packs are built. BuildKit lets a declared default beat the automatic
# value while a --build-arg beats the default (pinned with real builds), so
# a synthetic override for a name the file gives a declared default would
# reverse what the real build resolves. For those names no override is
# passed and BuildKit applies the declared default itself, exactly as the
# real build does; the expansion scan below applies the same precedence to
# its own table. The reader mirrors the main scan's global walk: a BOM, the
# directive block (the escape directive changes the continuation
# character), comments and blank lines dropped inside continuations,
# assignments split on whitespace with the name read up to the first =,
# stopping at the first FROM. Only names are read here; a token the main
# scan cannot take apart fails the run there, before the outline call.
DECLARED_AUTO=$(LC_ALL=C awk '
function scan_line(logical,   n, f, instr, ai, t, p, name) {
  sub("^" WS, "", logical)
  n = split(logical, f, WS)
  if (n == 0) return 0
  instr = toupper(f[1])
  if (instr == "FROM") return 1
  if (instr != "ARG") return 0
  for (ai = 2; ai <= n; ai++) {
    t = f[ai]
    p = index(t, "=")
    if (p <= 1) continue
    name = substr(t, 1, p - 1)
    if ((name in AUTO) && !(name in SEEN)) { SEEN[name] = 1; print name }
  }
  return 0
}
BEGIN {
  BOM = sprintf("%c%c%c", 239, 187, 191)
  WS  = sprintf("[ \t\r%c%c]+", 11, 12)
  CTRL_WS = sprintf("[%c%c\r]", 11, 12)
  ESC = "\\"
  directive_mode = 1
  buf = ""
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
    dline = trimmed
    gsub(CTRL_WS, " ", dline)
    if (dline ~ /^#[ \t]*[A-Za-z][A-Za-z0-9]*[ \t]*=[ \t]*[^ \t]/) {
      dkey = dline
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
  llen = length(line)
  if (substr(line, llen, 1) == ESC && (llen == 1 || substr(line, llen - 1, 1) != ESC)) {
    buf = buf substr(line, 1, llen - 1)
    next
  }
  buf = buf line
  logical = buf; buf = ""
  if (scan_line(logical)) exit 0
}
END { if (buf != "") scan_line(buf) }
' < "$DOCKERFILE")
DECLARED_AUTO=" $(printf '%s' "$DECLARED_AUTO" | tr '\n' ' ') "
declared_auto() {
  case "$DECLARED_AUTO" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Build the argument list: the platform packs first, then the user's
# --build-arg values so they override them, then the target. Each TARGET*
# and BUILD* value is overridden individually; BuildKit does not derive the
# others from an overridden TARGETPLATFORM, and a name with a declared
# global default gets no override, per the pre-scan above. Without
# --build-platform the
# BUILD* arguments stay the daemon's own platform, which is what a real
# build on this daemon uses. The values in USER_ARGS contain no newlines
# (checked above), so one line per argument is a faithful split; set -f
# keeps globbing out of the unquoted expansion. The normalized values are
# also kept for the expansion scan, which seeds them the way
# check-from-lines.sh does (there the BUILD* values default to the target
# platform when --build-platform is absent, the documented deviation the
# header names).
PLATFORM_SET=0
T_PLAT=""; T_OS=""; T_ARCH=""; T_VAR=""
B_PLAT=""; B_OS=""; B_ARCH=""; B_VAR=""
set -f
set --
if [ -n "$PLATFORM" ]; then
  PLATFORM_SET=1
  normalize_platform "$PLATFORM" --platform
  T_OS=$NORM_OS; T_ARCH=$NORM_ARCH; T_VAR=$NORM_VARIANT
  T_PLAT="$T_OS/$T_ARCH${T_VAR:+/$T_VAR}"
  declared_auto TARGETPLATFORM  || set -- "$@" --build-arg "TARGETPLATFORM=$T_PLAT"
  declared_auto TARGETOS        || set -- "$@" --build-arg "TARGETOS=$T_OS"
  declared_auto TARGETARCH      || set -- "$@" --build-arg "TARGETARCH=$T_ARCH"
  declared_auto TARGETVARIANT   || set -- "$@" --build-arg "TARGETVARIANT=$T_VAR"
  declared_auto TARGETOSVERSION || set -- "$@" --build-arg "TARGETOSVERSION="
fi
if [ -n "$BUILD_PLATFORM" ]; then
  normalize_platform "$BUILD_PLATFORM" --build-platform
  B_OS=$NORM_OS; B_ARCH=$NORM_ARCH; B_VAR=$NORM_VARIANT
  declared_auto BUILDPLATFORM  || set -- "$@" --build-arg "BUILDPLATFORM=$B_OS/$B_ARCH${B_VAR:+/$B_VAR}"
  declared_auto BUILDOS        || set -- "$@" --build-arg "BUILDOS=$B_OS"
  declared_auto BUILDARCH      || set -- "$@" --build-arg "BUILDARCH=$B_ARCH"
  declared_auto BUILDVARIANT   || set -- "$@" --build-arg "BUILDVARIANT=$B_VAR"
  declared_auto BUILDOSVERSION || set -- "$@" --build-arg "BUILDOSVERSION="
elif [ -n "$PLATFORM" ]; then
  B_OS=$T_OS; B_ARCH=$T_ARCH; B_VAR=$T_VAR
fi
[ -n "$PLATFORM" ] && B_PLAT="$B_OS/$B_ARCH${B_VAR:+/$B_VAR}"
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
TARGET_SET=0
[ -n "$TARGET_STAGE" ] && TARGET_SET=1

# --- the FROM set, from BuildKit's own stage graph --------------------------
# --call=targets returns every stage with its base as written, whatever the
# --target, so this covers the whole file like the textual gate. The call
# performs no resolution and needs no network.
tout=$(bounded docker buildx build --call=targets,format=json --progress=plain "$@" \
  -f "$DOCKERFILE" -- "$CONTEXT" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "check-from-oracle: the targets run failed (exit $rc); its output:"
  printf '%s\n' "$tout" | sed 's/^/  | /'
  pinned_frontend_check "$tout"
  not_a_pass "BuildKit could not enumerate the stages of this file"
fi
if ! printf '%s\n' "$tout" | grep -q '^#[0-9][0-9]* \[[^][]*\] load build definition from '; then
  printf '%s\n' "$tout" | sed 's/^/  | /'
  not_a_pass "the output shows no load-build-definition step, so there is no evidence the targets call ran on $DOCKERFILE"
fi
if ! printf '%s\n' "$tout" | grep -q '"targets"'; then
  printf '%s\n' "$tout" | sed 's/^/  | /'
  not_a_pass "the output has no targets JSON result (\"targets\"), so there is no evidence the targets call completed"
fi

# One line per stage, "name<TAB>base", in file order; the unnamed default
# stage has an empty name. The JSON prints one key per line with "name"
# before "base" inside each target (the shape of buildx 0.37, and the
# base64 "sources" strings cannot contain a quote, so no other line matches
# these keys). A value holding a JSON escape is refused below rather than
# decoded; no reference or stage name a build accepts contains a backslash.
stages=$(printf '%s\n' "$tout" | LC_ALL=C awk '
  /^[ \t]*"name": "/ {
    v = $0
    sub(/^[ \t]*"name": "/, "", v)
    sub(/",?[ \t]*$/, "", v)
    pending = v
    next
  }
  /^[ \t]*"base": "/ {
    v = $0
    sub(/^[ \t]*"base": "/, "", v)
    sub(/",?[ \t]*$/, "", v)
    print pending "\t" v
    pending = ""
  }
')
case "$stages" in
  *\\*) not_a_pass "a stage name or base in the targets output contains a JSON escape this script does not decode, so the FROM set cannot be read with certainty" ;;
esac
if [ -z "$stages" ]; then
  not_a_pass "no stage could be read from the targets output, so the FROM set is unknown"
fi

# Expand each base the way check-from-lines.sh resolves a FROM: the global
# ARG table (defaults, quoting, the user's --build-arg overrides), the
# automatic arguments as seeded from --platform, --build-platform, and
# --target with a declared default replacing the seeded value and an
# override beating both, as BuildKit applies them, and the named-context
# substitution. The scan rejects, rather than guesses at, an
# escape character in an ARG token, an expansion form beyond ${NAME},
# ${NAME:-word} and ${NAME:+word}, and an unresolved variable in a base.
# On success it prints one line per FROM-set member, "ref<TAB>canonical"
# (canonical fills in docker.io/library/ and :latest for the load matching
# below, and is empty for a ref that does not normalize); a base naming a
# stage (forward references included) and scratch are stage references,
# not pulls, and print nothing. A context whose name matches a stage's AS
# name replaces that stage's base before any of this, so the substituted
# reference is what enters the FROM set.
FROM_SET=$(CHECK_FROM_STAGES="$stages" CHECK_FROM_BUILD_ARGS="$USER_ARGS" \
  CHECK_FROM_BUILD_CONTEXTS="$BUILD_CONTEXTS" LC_ALL=C awk \
  -v platform_set="$PLATFORM_SET" -v tplat="$T_PLAT" -v tos="$T_OS" \
  -v tarch="$T_ARCH" -v tvar="$T_VAR" -v bplat="$B_PLAT" -v bos="$B_OS" \
  -v barch="$B_ARCH" -v bvar="$B_VAR" -v target_set="$TARGET_SET" \
  -v target_stage="$TARGET_STAGE" '
function fail(msg) { print msg; EXITCODE = 1; exit 1 }

function autofail(name, mode, where) {
  if (name in ARGS || !(name in AUTO)) return
  if (mode == "count") { COUNT_UNCERTAIN = 1; return }
  if (name == "TARGETSTAGE")
    fail(where " reads the automatic argument TARGETSTAGE, which BuildKit sets to the target stage name on every build. Pass --target so the gate resolves the same value the build does")
  fail(where " reads the automatic platform argument " name ", which BuildKit sets on every build. Pass --platform (and --build-platform when the build platform differs from the target) so the gate resolves the same file the builder does")
}

function lookup(name, mode, where) {
  autofail(name, mode, where)
  if (name in ARGS) return ARGS[name]
  if (mode == "from") UNRESOLVED = UNRESOLVED " " name
  if (mode == "count") COUNT_UNCERTAIN = 1
  return ""
}

# Expand $NAME, ${NAME}, ${NAME:-default}, ${NAME:+alt} in s, exactly as
# check-from-lines.sh does; any other modifier is rejected naming the
# expression. In mode "count" nothing is rejected: a form this expander
# cannot resolve sets COUNT_UNCERTAIN and returns instead, and the caller
# counts the source rather than failing a file the frontend may accept.
function expand_str(s, mode, where,   out, j, k, name, c, mod, word, isset) {
  out = ""
  while (length(s) > 0) {
    j = index(s, "$")
    if (j == 0) { out = out s; break }
    out = out substr(s, 1, j - 1)
    s = substr(s, j + 1)
    if (substr(s, 1, 1) == "{") {
      s = substr(s, 2)
      if (!match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
        if (mode == "count") { COUNT_UNCERTAIN = 1; return "" }
        fail("bad substitution \"${" s "\" at " where)
      }
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      c = substr(s, 1, 1)
      if (c == "}") {
        s = substr(s, 2)
        out = out lookup(name, mode, where)
      } else if (c == ":") {
        mod = substr(s, 2, 1)
        if (mod != "-" && mod != "+") {
          if (mode == "count") { COUNT_UNCERTAIN = 1; return "" }
          fail("unsupported modifier in \"${" name ":" mod "...}\" at " where ": only ${NAME}, ${NAME:-default} and ${NAME:+alt} are supported")
        }
        k = index(s, "}")
        if (k == 0) {
          if (mode == "count") { COUNT_UNCERTAIN = 1; return "" }
          fail("missing } in \"${" name s "\" at " where)
        }
        word = substr(s, 3, k - 3)
        s = substr(s, k + 1)
        if (word ~ /[${}"]/ || index(word, SQ) > 0 || index(word, ESC) > 0) {
          if (mode == "count") { COUNT_UNCERTAIN = 1; return "" }
          fail("unsupported nested expansion in \"${" name ":" mod word "}\" at " where)
        }
        autofail(name, mode, where)
        isset = (name in ARGS && ARGS[name] != "")
        if (mod == "-") out = out (isset ? ARGS[name] : word)
        else            out = out (isset ? word : "")
      } else if (c == "") {
        if (mode == "count") { COUNT_UNCERTAIN = 1; return "" }
        fail("missing } in \"${" name "\" at " where)
      } else {
        if (mode == "count") { COUNT_UNCERTAIN = 1; return "" }
        fail("unsupported variable modifier in \"${" name c "...}\" at " where ": only ${NAME}, ${NAME:-default} and ${NAME:+alt} are supported")
      }
    } else if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      out = out lookup(name, mode, where)
    } else {
      out = out "$"
    }
  }
  return out
}

# norm_ref(r): the same docker reference normalization as
# check-from-lines.sh (the two scripts share this function); the
# named-contexts fixtures pin each rule. The part before the first / is a
# registry host when it contains a dot or a colon, is exactly localhost,
# or is not all-lowercase (splitDockerDomain); the host keeps its case and
# compares byte-exact, and index.docker.io maps to docker.io only in that
# exact lowercase spelling.
function norm_ref(r,   host, rest, dig, tag, slash, last, colon, dpos) {
  if (r == "") return ""
  if (r ~ /[ \t\r]/ || index(r, VT) > 0 || index(r, FF) > 0) return ""
  dig = ""
  dpos = index(r, "@")
  if (dpos > 0) {
    dig = substr(r, dpos)
    r = substr(r, 1, dpos - 1)
    if (r == "" || length(dig) < 2) return ""
  }
  slash = index(r, "/")
  if (slash == 0) { host = "docker.io"; rest = r }
  else {
    host = substr(r, 1, slash - 1)
    if (host ~ /[.:]/ || host == "localhost" || host != tolower(host)) rest = substr(r, slash + 1)
    else { host = "docker.io"; rest = r }
  }
  if (host == "index.docker.io") host = "docker.io"
  if (host == "" || rest == "") return ""
  tag = ""
  last = rest
  sub(/^.*\//, "", last)
  colon = index(last, ":")
  if (colon > 0) {
    tag = substr(last, colon + 1)
    rest = substr(rest, 1, length(rest) - length(last) + colon - 1)
    if (tag == "" || tag ~ /[^A-Za-z0-9_.-]/ || length(tag) > 128) return ""
  }
  if (host == "docker.io" && index(rest, "/") == 0) rest = "library/" rest
  if (rest ~ /[^a-z0-9._\/-]/) return ""
  if (rest ~ /^[\/.]/ || rest ~ /[\/.]$/ || index(rest, "//") > 0) return ""
  if (tag == "" && dig == "") tag = "latest"
  if (tag != "") return host "/" rest ":" tag dig
  return host "/" rest dig
}

# member_line(resolved, where): serialize one FROM-set member as
# "ref<TAB>canonical" for the reader below. A member whose expanded form
# is empty or contains whitespace is rejected here, naming the base and
# its stage, instead of being serialized: BuildKit refuses an empty base
# (base name should not be blank, pinned by a real build), no reference
# the builder accepts contains whitespace, and the reader parses one
# member per line with a TAB between the fields, which such a member
# would break. The numeric check on the count line stays as the backstop,
# but a malformed member never reaches it.
function member_line(resolved, where) {
  if (resolved == "")
    fail(where " expands to an empty reference, which BuildKit refuses (base name should not be blank), so there is no base to check against the allowlist")
  if (resolved ~ /[ \t\r]/ || index(resolved, VT) > 0 || index(resolved, FF) > 0)
    fail(where " expands to a reference containing whitespace, which no reference the builder accepts contains, so the FROM set cannot be serialized or checked with certainty")
  return resolved "\t" norm_ref(resolved) "\n"
}

BEGIN {
  SQ = sprintf("%c", 39)
  VT = sprintf("%c", 11)
  FF = sprintf("%c", 12)
  BOM = sprintf("%c%c%c", 239, 187, 191)
  WS  = sprintf("[ \t\r%c%c]+", 11, 12)
  NWS = sprintf("[^ \t\r%c%c]+", 11, 12)
  CTRL_WS = sprintf("[%c%c\r]", 11, 12)
  ESC = "\\"
  directive_mode = 1
  buf = ""; bufline = 0
  done = 0
  n_auto = split("TARGETPLATFORM TARGETOS TARGETARCH TARGETVARIANT TARGETOSVERSION TARGETSTAGE BUILDPLATFORM BUILDOS BUILDARCH BUILDVARIANT BUILDOSVERSION", auto_names, " ")
  for (b = 1; b <= n_auto; b++) AUTO[auto_names[b]] = 1
  n_ba = split(ENVIRON["CHECK_FROM_BUILD_ARGS"], ba_lines, "\n")
  for (b = 1; b <= n_ba; b++) {
    if (ba_lines[b] == "") continue
    p = index(ba_lines[b], "=")
    if (p > 1) OVERRIDE[substr(ba_lines[b], 1, p - 1)] = substr(ba_lines[b], p + 1)
  }
  if (platform_set) {
    ARGS["TARGETPLATFORM"] = tplat
    ARGS["TARGETOS"] = tos
    ARGS["TARGETARCH"] = tarch
    ARGS["TARGETVARIANT"] = tvar
    ARGS["TARGETOSVERSION"] = ""
    ARGS["BUILDPLATFORM"] = bplat
    ARGS["BUILDOS"] = bos
    ARGS["BUILDARCH"] = barch
    ARGS["BUILDVARIANT"] = bvar
    ARGS["BUILDOSVERSION"] = ""
  }
  if (target_set) ARGS["TARGETSTAGE"] = target_stage
  for (b = 1; b <= n_auto; b++)
    if (auto_names[b] in OVERRIDE) ARGS[auto_names[b]] = OVERRIDE[auto_names[b]]
  N_CTX = 0
  n_bc = split(ENVIRON["CHECK_FROM_BUILD_CONTEXTS"], bc_lines, "\n")
  for (b = 1; b <= n_bc; b++) {
    if (bc_lines[b] == "") continue
    p = index(bc_lines[b], "=")
    if (p <= 1) continue
    cnorm = norm_ref(substr(bc_lines[b], 1, p - 1))
    if (cnorm == "")
      fail("the build context name \"" substr(bc_lines[b], 1, p - 1) "\" is not a valid image reference, so buildx refuses this invocation")
    CTX[cnorm] = substr(bc_lines[b], p + 1)
    N_CTX++
  }
  NSTAGE = split(ENVIRON["CHECK_FROM_STAGES"], stage_lines, "\n")
  for (b = 1; b <= NSTAGE; b++) {
    p = index(stage_lines[b], "\t")
    SN[b] = substr(stage_lines[b], 1, p - 1)
    SB[b] = substr(stage_lines[b], p + 1)
  }
}

{
  raw = $0
  if (NR == 1 && substr(raw, 1, 3) == BOM) raw = substr(raw, 4)
  line = raw
  sub(/\r$/, "", line); sub(/[ \t]+$/, "", line)
  trimmed = line
  sub("^" WS, "", trimmed)
  if (directive_mode) {
    # Directive lines normalize VT and FF to spaces before the match,
    # exactly as check-from-lines.sh does: BuildKit treats both as
    # whitespace inside a directive line, so an escape directive whose key
    # is prefixed with a VT byte is still honored (pinned by an outline
    # run that resolves through the backtick continuation it enables).
    dline = trimmed
    gsub(CTRL_WS, " ", dline)
    if (dline ~ /^#[ \t]*[A-Za-z][A-Za-z0-9]*[ \t]*=[ \t]*[^ \t]/) {
      dkey = dline
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
  process_global(logical, bufline)
}

# art_source(v, lineno): decide whether a COPY --from= or RUN --mount from=
# source can pull an image, and count it in ART when it can. A source
# naming a declared stage is a stage reference, never a pull, so it does
# not count: the raw value is expanded with the same global ARG table the
# FROM set uses, then matched against the stage graph by AS name
# (case-insensitively, as BuildKit matches stage names) and by in-range
# numeric stage index. BuildKit reads the index with strconv.Atoi, so an
# optional leading plus sign is part of it (a real cacheonly build copies
# from stage 0 with --from=+0), while a negative or out-of-range index
# fails the build as an invalid stage index, so such a value stays
# counted. A value this expander cannot resolve (an escape
# character, an unresolved variable, a form beyond ${NAME}, ${NAME:-word}
# and ${NAME:+word}) counts rather than fails, because overstating the
# count only leaves an off-set load on the artifact-report path, while
# failing would reject files the frontend accepts. A named context cannot
# change the classification: a context matching the AS name of a stage
# replaces the base of that stage while the stage stays a stage, and a
# context matching anything else replaces a source that already counts.
function art_source(v, lineno,   ev, evn, oth) {
  if (index(v, ESC) > 0) { ART++; return }
  COUNT_UNCERTAIN = 0
  ev = expand_str(v, "count", "line " lineno)
  if (COUNT_UNCERTAIN) { ART++; return }
  evn = ev
  sub(/^[+]/, "", evn)
  if (evn ~ /^[0-9]+$/ && evn + 0 < NSTAGE) return
  for (oth = 1; oth <= NSTAGE; oth++)
    if (SN[oth] != "" && tolower(SN[oth]) == tolower(ev)) return
  ART++
}

# run_flags(s, lineno): walk the flag region of a RUN the way the BuildKit
# flag extraction walks it, each rule pinned by a real cacheonly build on
# this daemon (Docker 29.8, buildx 0.37). A single or double quote opens a
# quoted span whose whitespace stays inside the flag word, the quote
# characters themselves are dropped before the value is split, and a quote
# still open at the end of the line swallows the rest of the line into the
# word, which the build accepts, honoring a from= source inside the
# swallowed span and never reaching a --mount written after it. The flag
# region ends at the first word that does not begin with --, which starts
# the command. Each --mount= word hands its value to mount_value.
function run_flags(s, lineno,   L, i, c, q, word) {
  sub("^" WS, "", s)
  sub("^" NWS, "", s)
  for (;;) {
    sub("^" WS, "", s)
    if (substr(s, 1, 2) != "--") return
    word = ""
    q = ""
    L = length(s)
    for (i = 1; i <= L; i++) {
      c = substr(s, i, 1)
      if (q != "") {
        if (c == q) q = ""
        else word = word c
      } else if (c == "\"" || c == SQ) q = c
      else if (c == " " || c == "\t" || c == "\r" || c == VT || c == FF) break
      else word = word c
    }
    s = substr(s, i + 1)
    if (substr(word, 1, 8) == "--mount=") mount_value(substr(word, 9), lineno)
  }
}

# mount_value(v, lineno): split one --mount value (quotes already dropped
# by run_flags) into key=value options the way BuildKit splits it, pinned
# by real cacheonly builds. A comma splits fields even when the file wrote
# it between quotes ("from=REF,target=/mnt" mounts REF at /mnt), each
# field splits at its first = with the key lowercased and compared whole
# (a key holding a leading space fails the build naming the key), and a
# field without = is a bare option such as readonly, which cannot pull. A
# backslash or the escape character anywhere in the value makes the split
# uncertain, because the BuildKit flag extraction consumes escape characters
# this scan does not model, so the mount counts as artifact-capable
# instead, which can only overstate the count and leave an off-set load on
# the artifact-report path, never reject a file the frontend accepts.
function mount_value(v, lineno,   nmo, mo, mi, meq) {
  if (index(v, "\\") > 0 || index(v, ESC) > 0) { ART++; return }
  nmo = split(v, mo, ",")
  for (mi = 1; mi <= nmo; mi++) {
    meq = index(mo[mi], "=")
    if (meq == 0) continue
    if (tolower(substr(mo[mi], 1, meq - 1)) != "from") continue
    art_source(substr(mo[mi], meq + 1), lineno)
  }
}

function process_global(logical, lineno,   n, f, instr, ai, t, p, name, val, q, inner, litq, fi) {
  sub("^" WS, "", logical)
  n = split(logical, f, WS)
  if (n == 0) return
  instr = toupper(f[1])
  # Count the instructions that can pull an image other than FROM, on the
  # joined logical lines across the whole file: a COPY with a --from= flag
  # and a RUN with a --mount= flag whose value carries a from= source,
  # except when the source names a declared stage (art_source above holds
  # the rules). The count feeds the unexpanded-base fallback below the
  # outline run; when it is zero, a resolved load outside the FROM set can
  # only be a base this scan expanded differently than the frontend. The
  # count reads heredoc bodies as instructions (this scan does not track
  # heredocs), so a file can overstate it, which only leaves such a load
  # on the artifact-report path it is on today, never rejects a good file.
  # Mount option keys match case-insensitively because BuildKit lowercases
  # them before matching: a real cacheonly build on this daemon (Docker
  # 29.8, buildx 0.37) accepts --mount=type=bind,FROM=alpine:3.19,
  # target=/mnt and serves the image content into the mount, and the Type=
  # and From= spellings build the same, while an unknown key fails the
  # build naming it. The RUN flags are walked on the raw logical line by
  # run_flags above, not on the whitespace-split fields, because a quoted
  # span in a mount value keeps its whitespace inside the flag word.
  if (instr == "COPY") {
    for (fi = 2; fi <= n && substr(f[fi], 1, 2) == "--"; fi++)
      if (substr(f[fi], 1, 7) == "--from=") art_source(substr(f[fi], 8), lineno)
    return
  }
  if (instr == "RUN") {
    run_flags(logical, lineno)
    return
  }
  if (instr == "FROM") { done = 1; return }
  if (done) return
  if (instr != "ARG") return
  for (ai = 2; ai <= n; ai++) {
    t = f[ai]
    if (index(t, ESC) > 0)
      fail("line " lineno " has an ARG token containing the escape character; this script cannot tell what it declares, so the file is rejected rather than guessed at")
    p = index(t, "=")
    if (p == 0) {
      if (t ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (t in OVERRIDE)) ARGS[t] = OVERRIDE[t]
      continue
    }
    if (p == 1)
      fail("ARG at line " lineno " declares an assignment with an empty name (\"" t "\")")
    name = substr(t, 1, p - 1)
    val = substr(t, p + 1)
    # A declared default for an automatic argument name replaces the
    # seeded value through this same assignment, and an OVERRIDE entry
    # beats it below, matching the precedence BuildKit applies (declared
    # default over automatic value, --build-arg over the default, each
    # pinned with real builds); the pack builder passed no synthetic
    # override for such a name, so the frontend applies the same default.
    litq = 0
    if (index(val, "\"") > 0 || index(val, SQ) > 0) {
      q = substr(val, 1, 1)
      inner = substr(val, 2, length(val) - 2)
      if ((q != "\"" && q != SQ) || length(val) < 2 || substr(val, length(val), 1) != q || index(inner, q) > 0)
        fail("ARG at line " lineno " has a quoted value this script cannot take apart (\"" t "\"); a quoted value spanning whitespace or a stray quote is rejected rather than reassembled")
      val = inner
      if (q == SQ) litq = 1
    }
    if (name in OVERRIDE) ARGS[name] = OVERRIDE[name]
    else if (litq) ARGS[name] = val
    else ARGS[name] = expand_str(val, "default", "line " lineno)
  }
}

END {
  if (EXITCODE) exit EXITCODE
  if (buf != "") process_global(buf, bufline)
  if (EXITCODE) exit EXITCODE
  outbuf = ""
  for (i = 1; i <= NSTAGE; i++) {
    base = SB[i]
    where = "the base \"" base "\" of stage " i
    if (SN[i] != "") where = where " (" SN[i] ")"
    # A context whose name matches the AS name of this stage applies at
    # the stage definition, replacing the base of the stage even when no FROM
    # references the name, with reference normalization on the name and
    # case-insensitively on the stage name, beating a context matching the
    # base reference and a scratch base alike (each rule pinned by an
    # outline run; the scratch replacement by a real cacheonly build). The
    # base as written is never pulled, so the context source enters the
    # FROM set in its place, before any expansion of the written base, and
    # the outline load for it matches the set.
    if (N_CTX > 0 && SN[i] != "") {
      an = norm_ref(tolower(SN[i]))
      if (an != "" && (an in CTX)) {
        csrc = CTX[an]
        if (substr(csrc, 1, 15) != "docker-image://")
          fail("the stage " SN[i] " is overridden by a --build-context whose source (" csrc ") is not a docker-image:// reference; BuildKit builds the stage from that source in place of its base, and a base taken from a local directory, a git repository, an oci layout, or another build target cannot be checked against the allowlist, so a named context of that kind is unsupported for a stage name")
        resolved = substr(csrc, 16)
        if (resolved == "")
          fail("the stage " SN[i] " is overridden by a --build-context with an empty docker-image:// reference")
        outbuf = outbuf member_line(resolved, where)
        continue
      }
    }
    UNRESOLVED = ""
    resolved = expand_str(base, "from", where)
    if (UNRESOLVED != "")
      fail(where " has unresolved ARG variable(s):" UNRESOLVED ", so the FROM set cannot be expanded")
    if (resolved == "scratch") continue
    handled = 0
    if (N_CTX > 0) {
      cn = norm_ref(resolved)
      if (cn != "" && (cn in CTX)) {
        csrc = CTX[cn]
        if (substr(csrc, 1, 15) != "docker-image://")
          fail(where " resolves to \"" resolved "\", which a --build-context overrides with a source (" csrc ") that is not a docker-image:// reference; a base taken from a local directory, a git repository, an oci layout, or another build target cannot be checked against the allowlist, so a named context of that kind is unsupported for a base")
        resolved = substr(csrc, 16)
        if (resolved == "")
          fail(where " is overridden by a --build-context with an empty docker-image:// reference")
        handled = 1
      }
    }
    # A base is a stage reference only when some other stage bears that
    # name. A stage cannot be its own base, so FROM alpine AS alpine pulls
    # the image and must meet the allowlist like any other base.
    if (!handled) {
      isstage = 0
      for (oth = 1; oth <= NSTAGE; oth++)
        if (oth != i && SN[oth] != "" && tolower(SN[oth]) == tolower(resolved)) { isstage = 1; break }
      if (isstage) continue
    }
    outbuf = outbuf member_line(resolved, where)
  }
  # The artifact-capable count travels on the first output line, which
  # begins with a TAB so no FROM-set member can imitate it: a member line
  # begins with its reference, and no reference the builder accepts begins
  # with a TAB. The FROM-set members follow, one per line.
  printf "\tartifact-capable\t%d\n", ART
  printf "%s", outbuf
}
' < "$DOCKERFILE")
rc=$?
if [ "$rc" -ne 0 ]; then
  not_a_pass "$FROM_SET"
fi

mirror=$(printf '%s' "$MIRROR" | tr '[:upper:]' '[:lower:]' | sed 's:/*$::; s/^[ 	]*//; s/[ 	]*$//')
TAB=$(printf '\t')

# Every member of the FROM set must be on the allowlist; a rejected member
# fails the gate before the outline runs. The member prints in canonical
# form when it has one, matching what the build's load lines show. The
# scan's count line carries the number of artifact-capable instructions
# for the unexpanded-base fallback below; it is the only line beginning
# with a TAB, so a base written as artifact-capable stays a member and
# meets the allowlist like any other. A count that is missing or not a
# number fails the run below, never passes it.
fromset_match="$NL"
fail=0
ART_CAPABLE=""
old_ifs=$IFS
IFS=$NL
for line in $FROM_SET; do
  [ -n "$line" ] || continue
  case "$line" in
    "$TAB"artifact-capable"$TAB"*)
      ART_CAPABLE=${line##*"$TAB"}
      continue
      ;;
  esac
  member=${line%%"$TAB"*}
  canon=${line#*"$TAB"}
  disp=$member
  [ -n "$canon" ] && disp=$canon
  lc=$(printf '%s' "$disp" | tr '[:upper:]' '[:lower:]')
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
    echo "check-from-oracle: allowed  $disp"
  else
    echo "check-from-oracle: REJECTED $disp — not on cgr.dev/* or the configured external mirror"
    fail=1
  fi
  fromset_match="$fromset_match$member$NL"
  [ -n "$canon" ] && fromset_match="$fromset_match$canon$NL"
done
IFS=$old_ifs

if [ "$fail" -ne 0 ]; then
  echo "check-from-oracle: the file's FROM set contains at least one base image off the allowlist"
  exit 1
fi

# Fail closed on a count the scan did not report as a number; the fallback
# below compares it arithmetically, and an unreadable count must never
# widen the artifact path or pass the gate.
case "$ART_CAPABLE" in
  ''|*[!0-9]*)
    not_a_pass "the FROM-set scan reported no numeric artifact-capable count (got '$ART_CAPABLE'), so the unexpanded-base fallback cannot be trusted"
    ;;
esac

# --- resolution and artifact sources, from the outline run ------------------
out=$(bounded docker buildx build --call=outline,format=json --progress=plain "$@" \
  -f "$DOCKERFILE" -- "$CONTEXT" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "check-from-oracle: the outline run failed (exit $rc); its output:"
  printf '%s\n' "$out" | sed 's/^/  | /'
  pinned_frontend_check "$out"
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
# the run naming the line. A load matching the FROM set (as written or in
# canonical form) is a base the check above already vouched for; every
# other load is an external artifact source (COPY --from, a RUN mount,
# ADD from an image), which references/from-and-registry-rules.md permits
# and asks the report to name, so it is printed and allowed. A reference
# that is both a base and an artifact source is in the FROM set and was
# checked as a base.
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

# The unexpanded-base fallback: a load outside the FROM set is an artifact
# source only when the file has at least one instruction that can pull an
# image other than FROM. When it has none, such a load can only be a base
# this script's scan expanded differently than the frontend did, so the
# run fails naming it. This is the fallback for any divergence between the
# scan and the frontend: whatever the scan misreads, the extra load
# surfaces here instead of passing as an artifact source.
for ref in $refs; do
  case "$fromset_match" in
    *"$NL$ref$NL"*) : ;;
    *)
      if [ "$ART_CAPABLE" -eq 0 ]; then
        echo "check-from-oracle: REJECTED $ref — the build resolves it, it is not in the FROM set, and the file has no COPY --from= and no RUN --mount= with a from= source that could pull an artifact, so it is an unexpanded base: this script's scan and the frontend disagree about the file"
        echo "check-from-oracle: this is not a pass; the FROM gate fails."
        exit 1
      fi
      echo "check-from-oracle: WARNING: external artifact source $ref (COPY --from, RUN mount, or ADD): a binary copied from another distribution's image links against that distribution's libraries; prefer the Chainguard image of the same name or build the artifact in a Chainguard stage"
      ;;
  esac
done

if [ "$fromset_match" = "$NL" ]; then
  echo "check-from-oracle: OK — the stages of $DOCKERFILE resolve no external base images"
  exit 0
fi
echo "check-from-oracle: OK — every base image in the FROM set of $DOCKERFILE is on the allowlist"
exit 0
