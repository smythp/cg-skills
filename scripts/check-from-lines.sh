#!/bin/sh
# check-from-lines.sh — gate every FROM in a Dockerfile against the migration
# allowlist: cgr.dev/* (exact host boundary), the configured external mirror
# prefix (on a / boundary), scratch, and previously declared stage aliases.
#
# Usage: check-from-lines.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]]
#                            [--build-platform OS/ARCH[/VARIANT]] [--target NAME]
#                            [--build-arg NAME=value ...]
#                            [--build-context NAME=SOURCE ...] DOCKERFILE
#   --mirror PREFIX       external pull-through mirror, e.g. my-corp.example.io/cg
#   --platform P          the platform of the captured build invocation, or
#                         the daemon's default when the invocation names
#                         none. Seeds the automatic platform arguments
#                         (TARGETPLATFORM, TARGETOS, TARGETARCH,
#                         TARGETVARIANT, TARGETOSVERSION, BUILDPLATFORM,
#                         BUILDOS, BUILDARCH, BUILDVARIANT, BUILDOSVERSION)
#                         the way BuildKit does. One platform per run; a
#                         multi-platform build is gated once per platform.
#   --build-platform P    the platform of the machine running the build.
#                         Without it the BUILD* arguments default to the
#                         target platform, which matches every same-platform
#                         build; a build that crosses platforms should pass
#                         the daemon's platform here, because docker sets
#                         BUILD* to the builder's own platform.
#   --target NAME         the build target from the captured invocation.
#                         Seeds TARGETSTAGE, which BuildKit sets to the
#                         target stage's name (or the final stage's).
#   --build-arg NAME=value  a build arg from the captured build invocation;
#                         repeatable. docker build honors these over the
#                         Dockerfile's ARG defaults, so the gate must apply
#                         the same overrides or it checks a different file
#                         than the one being built. Overrides of the
#                         automatic arguments above apply even with no ARG
#                         declaration, as in docker build.
#   --build-context NAME=SOURCE  a named build context from the captured
#                         invocation; repeatable, last value per name wins,
#                         as in buildx. BuildKit replaces a FROM whose
#                         reference or stage name matches NAME (after
#                         reference normalization on both sides), and it
#                         applies a NAME matching a stage's AS name at the
#                         stage's definition, replacing that stage's base
#                         even when no FROM references the name, so a gate
#                         run without these checks a different base than
#                         the one being built. A docker-image:// source
#                         replaces the FROM reference (or the overridden
#                         stage's base) for the check; any other source
#                         kind matching a FROM or a stage name is rejected,
#                         because a base taken from a directory, git
#                         repository, oci layout, or another target cannot
#                         be checked against a registry allowlist. A NAME
#                         matching no FROM and no stage name is ignored,
#                         as BuildKit ignores it for bases.
#
# Exit codes: 0 = all FROMs allowed; 1 = a FROM (or stage alias, or ARG
# expansion, or a construct this gate refuses to guess about) is not allowed,
# with a message naming the line; 2 = usage error.
#
# Semantics ported from Guardener's static validator and checked against
# BuildKit (the parser rules below were each verified against
# docker buildx build --call=outline on the builtin Dockerfile frontend):
#   - Physical lines: a NUL byte anywhere in the file, and a CR that is not
#     immediately followed by LF, are rejected before parsing, naming the
#     line. BuildKit keeps both bytes inside the surrounding line where this
#     parser would split it (its FROM reproductions fail with "FROM requires
#     either one or three arguments"), awk implementations disagree about
#     NUL bytes in input, and once the file is split into records a final CR
#     with no LF cannot be told apart from a CRLF ending. CRLF line endings
#     are accepted as before.
#   - Parser directives: consecutive '# key=value' lines from the top of the
#     file (leading whitespace and a UTF-8 BOM allowed, keys case-insensitive).
#     The block ends at the first line that is not a known directive (a
#     plain comment, a blank line, an unknown key, or an instruction). '# escape=' is
#     honored for backslash and backtick; any other value is rejected with
#     exit 1, as BuildKit itself errors on it. A duplicate directive is
#     rejected the same way. '# syntax=' is accepted only when its value is
#     exactly docker/dockerfile:1 or docker.io/docker/dockerfile:1, the
#     rolling tag of the frontend these rules were verified against; every
#     other value is rejected naming the frontend. A pinned tag parses by
#     the pin's rules, not the rolling frontend's (under docker/dockerfile:1.0
#     a heredoc body is ordinary instructions), and buildx can answer a
#     --call=outline for a pinned frontend through a different,
#     subrequest-capable frontend, so neither this gate nor the outline
#     oracle can vouch for what a pinned frontend builds.
#   - Line continuation matches BuildKit: a line continues when its last
#     non-whitespace character is the escape character and the character
#     before it is not also the escape character (so a line ending in two
#     escape characters does not continue). Joined lines are concatenated
#     without an inserted separator, as BuildKit joins them. Comment lines
#     and blank lines inside a continuation are skipped and the continuation
#     goes on, matching BuildKit's empty-continuation-line behavior.
#   - Heredocs on RUN, COPY, ADD, and ONBUILD RUN/COPY/ADD: <<NAME, <<-NAME,
#     <<'NAME', <<"NAME", an optional leading file-descriptor digit string
#     (2<<NAME), and BuildKit's separated form << NAME (the lexer glues the
#     whitespace and the following word into one heredoc word; <<- NAME with
#     a space is NOT a heredoc, and a bare << at end of line is not either).
#     Heredoc markers are found by tokenizing the whole logical line the way
#     BuildKit's heredoc scan does: unquoted whitespace splits words, single
#     and double quotes run to their closing quote, a backslash escapes the
#     next character (inside double quotes it escapes ", $ and backslash),
#     and a heredoc starts only at a word whose unquoted start is the
#     optional digits and <<. So << inside a quoted string is plain text,
#     while a real heredoc after a quoted string on the same line still
#     counts. This tokenizer always escapes with backslash: BuildKit
#     hardcodes it for heredoc scanning even when '# escape=`' changes the
#     escape character (verified against the oracle). A line this tokenizer
#     cannot split with certainty is rejected with exit 1 rather than
#     guessed at: an unbalanced quote (BuildKit silently scans no heredocs
#     on such a line), a ${...} expansion on a heredoc-capable line in any
#     form other than ${NAME}, ${NAME:-word} or ${NAME:+word} with a plain
#     word (other forms can shift BuildKit's word boundaries or disable its
#     heredoc scan entirely), and a Unicode space character on such a line
#     (BuildKit splits words on those; this byte-wise scan cannot). The
#     content lines up to and including the line equal to each delimiter, in
#     order, are file content, not instructions and not comments; for <<-
#     the delimiter comparison strips leading tabs; otherwise the comparison
#     is exact, so a delimiter line with trailing whitespace does not
#     terminate. A heredoc marker this gate cannot classify with certainty
#     (a quoted name spanning whitespace, a name containing a quote, $, a
#     backslash, or other unusual characters) is rejected with exit 1 rather
#     than guessed at, and an unterminated heredoc is rejected as BuildKit
#     rejects it.
#   - ARG lines before the first FROM: every NAME=value assignment on the
#     line is processed, matching docker build, not just the first. A value
#     may be wrapped in one pair of quotes; a single-quoted value is kept
#     literally, with no variable expansion inside it, as BuildKit keeps it
#     (verified with an outline run), while double-quoted and unquoted
#     values expand. A quoted value spanning
#     whitespace, a stray quote, or an escape character in any token is
#     rejected with exit 1 rather than reassembled. ARGs declared after a
#     FROM are ignored for FROM resolution. A --build-arg override replaces
#     the default of a matching ARG declared before the first FROM, and gives
#     a value to a global ARG declared with no default. An override whose
#     name no ARG declares is ignored, as in docker build. A global ARG
#     that declares a default for one of the automatic argument names is
#     rejected with exit 1 naming the line (see the automatic arguments
#     bullet); a bare redeclaration stays allowed.
#   - Variable expansion supports $NAME, ${NAME}, ${NAME:-default} (default
#     when unset or empty) and ${NAME:+alt} (alt when set and non-empty),
#     with BuildKit's semantics. Every other modifier (%, #, /, ^, and the
#     colon-less - and + forms) is rejected with exit 1 naming the
#     expression, never expanded to an empty string.
#   - FROM flags such as --platform=... are skipped to reach the image ref.
#     After the flags, a FROM has exactly one image reference, optionally
#     followed by AS and a stage name; any other token count is rejected
#     quoting the line, as BuildKit fails such a line with "FROM requires
#     either one or three arguments" (a middle token other than AS draws the
#     same message). scratch is matched case-sensitively; BuildKit treats
#     only the lowercase spelling as the empty base and rejects FROM SCRATCH
#     as an invalid reference (repository names must be lowercase).
#   - Automatic platform arguments: BuildKit seeds TARGETPLATFORM, TARGETOS,
#     TARGETARCH, TARGETVARIANT, TARGETOSVERSION, TARGETSTAGE, BUILDPLATFORM,
#     BUILDOS, BUILDARCH, BUILDVARIANT, and BUILDOSVERSION in the global
#     scope on every build, so a FROM (or a global ARG default) can read
#     them with no declaration. When the gate runs with --platform it seeds
#     the same values, normalized the way the docker CLI normalizes a
#     platform string (containerd platforms.Normalize: x86_64 and aarch64
#     become amd64 and arm64, i386 becomes 386 and drops any variant, armhf
#     and armel become arm/v7 and arm/v6 replacing any variant, amd64 drops
#     a v1 variant, arm64 drops an 8 or v8 variant, bare arm becomes arm/v7
#     and the numeric arm variants 5, 6, 7, 8 gain the v prefix; each rule
#     verified against a real build). TARGETVARIANT and the OSVERSION
#     arguments are set to the
#     empty string when the platform has none, which matters for the :- and
#     :+ modifiers. A bare global redeclaration (ARG TARGETARCH) keeps the
#     seeded value, matching BuildKit, and a --build-arg override beats a
#     declaration with or without it. A global declaration that gives one
#     of these names a default is rejected with exit 1 naming the line.
#     BuildKit lets the declared default beat the automatic value while a
#     --build-arg beats the default, and the oracle gate can pass a
#     platform only as --build-arg overrides, so such a file would resolve
#     differently under the oracle than under the build. BuildKit itself
#     accepts the file, so this rejection is conservative, and it keeps
#     the two gate scripts answering for the same file.
#     When --platform was not given and FROM resolution
#     reads one of these names, the gate exits 1 naming it and asking for
#     --platform (or --target, for TARGETSTAGE), because BuildKit resolves
#     a value the gate does not know. A file that never reads them behaves
#     as before.
#   - Unresolved variables in a FROM ref are rejected: FROM $UNSET could
#     resolve to anything at build time, so it cannot pass a static gate.
#   - Named build contexts: BuildKit matches each --build-context name
#     against the expanded FROM reference and against stage names, after
#     docker reference normalization on both sides (a bare name gains
#     docker.io/library/ and :latest, index.docker.io maps to docker.io in
#     that exact lowercase spelling only, the registry host compares
#     byte-exact with its case preserved, a digest reference matches only
#     the exact digest string). A name matching a stage's AS name applies
#     at the stage's definition, replacing that stage's base even when no
#     FROM references the name, and it beats a context matching the base
#     reference and a scratch base alike; at a FROM, a context beats a
#     stage of the same name, while FROM scratch itself cannot be
#     overridden by a context named scratch; each rule pinned by an
#     outline run or a real build. The gate applies the same matching at
#     each FROM and at each AS name. A matching docker-image://REF source
#     puts REF through the allowlist in place of the FROM (or of the
#     overridden stage's base); a matching source of any other kind is
#     rejected as unsupported; a name that matches nothing is ignored.
#   - A stage alias must match ^[a-zA-Z][a-zA-Z0-9_.-]*$ (Docker stage-name
#     rules) so an image-shaped alias cannot become a trusted name for later
#     FROMs. Aliases compare case-insensitively.
#   - Lookalike hosts (cgr.dev.evil.example.com) and mirror prefix siblings
#     (mirror-extra/...) are rejected by the boundary checks.
#
# Known conservative deviations (this gate may reject what Docker accepts,
# never the reverse): the modifiers beyond ${NAME:-default} and ${NAME:+alt},
# quoted or escaped whitespace in ARG values, ambiguous heredoc markers,
# unbalanced quotes and restricted ${...} forms and Unicode spaces on
# heredoc-capable lines, and non-stable '# syntax=' frontends are all
# rejected rather than emulated; a NUL byte or a bare CR is rejected
# file-wide, even where BuildKit tolerates it (inside a comment or a heredoc
# body, and a final CR with no LF, which BuildKit reads as an ordinary line
# ending, verified against a real outline run); a global ARG that declares
# a default for an automatic argument name is rejected even though BuildKit
# accepts the file (the automatic arguments bullet above says why); a
# --build-context whose source is not docker-image:// is rejected when its
# name matches a FROM or a stage name, where BuildKit would build the base
# from that source; and with --platform but no
# --build-platform the BUILD* arguments take the target platform's values,
# which matches every same-platform build but differs on a cross-platform
# one until the caller passes --build-platform.
#
# Dependencies: sh, awk, od (POSIX). No network, no writes.

set -u

NL='
'

MIRROR=""
BUILD_ARGS=""
BUILD_CONTEXTS=""
PLATFORM=""
BUILD_PLATFORM=""
TARGET_STAGE=""
TARGET_SET=0

# normalize_platform VALUE FLAG: split VALUE into NORM_OS, NORM_ARCH,
# NORM_VARIANT and apply the normalizations the docker CLI applies before
# the builder sees the platform (containerd platforms.Normalize; the rules
# are listed at the case block below, each verified against a real build).
normalize_platform() {
  np_val=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$np_val" in
    *,*)
      echo "check-from-lines.sh: $2 takes one platform per run (got '$1'); a multi-platform build is gated once per platform" >&2
      exit 2
      ;;
  esac
  case "$np_val" in
    */*) : ;;
    *)
      echo "check-from-lines.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
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
    echo "check-from-lines.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
    exit 2
  fi
  case "$np_rest" in
    */*)
      case "$NORM_VARIANT" in
        ''|*/*)
          echo "check-from-lines.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
          exit 2
          ;;
      esac
      ;;
  esac
  case "${NORM_OS}${NORM_ARCH}${NORM_VARIANT}" in
    *[!a-z0-9_.-]*)
      echo "check-from-lines.sh: $2 must look like OS/ARCH or OS/ARCH/VARIANT, got '$1'" >&2
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
      [ -n "$MIRROR" ] || { echo "check-from-lines.sh: --mirror needs a value" >&2; exit 2; }
      shift 2
      ;;
    --platform)
      PLATFORM="${2-}"
      [ -n "$PLATFORM" ] || { echo "check-from-lines.sh: --platform needs a value" >&2; exit 2; }
      shift 2
      ;;
    --build-platform)
      BUILD_PLATFORM="${2-}"
      [ -n "$BUILD_PLATFORM" ] || { echo "check-from-lines.sh: --build-platform needs a value" >&2; exit 2; }
      shift 2
      ;;
    --target)
      TARGET_STAGE="${2-}"
      case "$TARGET_STAGE" in
        ''|*[!A-Za-z0-9_.-]*)
          echo "check-from-lines.sh: --target needs a stage name (letters, digits, _ . -)" >&2
          exit 2
          ;;
      esac
      TARGET_SET=1
      shift 2
      ;;
    --build-arg)
      ba="${2-}"
      case "$ba" in
        ''|=*) echo "check-from-lines.sh: --build-arg needs NAME=value" >&2; exit 2 ;;
        *=*) : ;;
        *) echo "check-from-lines.sh: --build-arg needs NAME=value, got '$ba'" >&2; exit 2 ;;
      esac
      case "$ba" in
        *"$NL"*) echo "check-from-lines.sh: a --build-arg value must not contain a newline" >&2; exit 2 ;;
      esac
      BUILD_ARGS="${BUILD_ARGS}${ba}${NL}"
      shift 2
      ;;
    --build-context)
      bc="${2-}"
      case "$bc" in
        ''|=*) echo "check-from-lines.sh: --build-context needs NAME=SOURCE" >&2; exit 2 ;;
        *=*) : ;;
        *) echo "check-from-lines.sh: --build-context needs NAME=SOURCE, got '$bc'" >&2; exit 2 ;;
      esac
      case "$bc" in
        *"$NL"*) echo "check-from-lines.sh: a --build-context value must not contain a newline" >&2; exit 2 ;;
      esac
      BUILD_CONTEXTS="${BUILD_CONTEXTS}${bc}${NL}"
      shift 2
      ;;
    *) break ;;
  esac
done

DOCKERFILE="${1-}"
if [ -z "$DOCKERFILE" ] || [ ! -f "$DOCKERFILE" ]; then
  echo "usage: check-from-lines.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]] [--build-platform OS/ARCH[/VARIANT]] [--target NAME] [--build-arg NAME=value ...] [--build-context NAME=SOURCE ...] DOCKERFILE" >&2
  exit 2
fi

if [ -n "$BUILD_PLATFORM" ] && [ -z "$PLATFORM" ]; then
  echo "check-from-lines.sh: --build-platform needs --platform as well" >&2
  exit 2
fi

# NUL bytes and bare CRs (a CR not immediately followed by LF) are rejected
# before parsing, naming the line, for the reasons in the header. The scan
# walks od's octal byte dump so no awk implementation ever reads the bytes
# themselves; the line count follows LF bytes, and a CR as the very last
# byte of the file is caught by the END block.
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
    NUL*)
      echo "check-from-lines: line ${BAD_BYTE#* } contains a NUL byte; this gate cannot split such a line the way BuildKit does, so the file is rejected rather than guessed at"
      ;;
    *)
      echo "check-from-lines: line ${BAD_BYTE#* } contains a CR that is not part of a CRLF line ending; this gate cannot split such a line the way BuildKit does, so the file is rejected rather than guessed at (CRLF endings are accepted)"
      ;;
  esac
  exit 1
fi

# Resolve the automatic platform argument values BuildKit would seed. The
# BUILD* values default to the target platform; a cross-platform build
# passes --build-platform (see the usage note).
PLATFORM_SET=0
T_PLAT=""; T_OS=""; T_ARCH=""; T_VAR=""
B_PLAT=""; B_OS=""; B_ARCH=""; B_VAR=""
if [ -n "$PLATFORM" ]; then
  PLATFORM_SET=1
  normalize_platform "$PLATFORM" --platform
  T_OS=$NORM_OS; T_ARCH=$NORM_ARCH; T_VAR=$NORM_VARIANT
  T_PLAT="$T_OS/$T_ARCH${T_VAR:+/$T_VAR}"
  if [ -n "$BUILD_PLATFORM" ]; then
    normalize_platform "$BUILD_PLATFORM" --build-platform
    B_OS=$NORM_OS; B_ARCH=$NORM_ARCH; B_VAR=$NORM_VARIANT
  else
    B_OS=$T_OS; B_ARCH=$T_ARCH; B_VAR=$T_VAR
  fi
  B_PLAT="$B_OS/$B_ARCH${B_VAR:+/$B_VAR}"
fi

# Build args and the mirror prefix travel through the environment, not -v:
# awk -v runs backslash escape processing on the value, which would corrupt
# a value containing one.
# The Dockerfile is fed on stdin, not as an operand: a bare operand shaped
# like name=value is treated by POSIX awk as a variable assignment, so a file
# literally named "from=allowed" would never be read and the gate would pass.
# LC_ALL=C keeps awk bytewise: in a UTF-8 locale, gawk builds sprintf("%c")
# strings and indexes substrings by character, which would break the BOM
# comparison and the Unicode-space detection.
# The platform values reach awk through -v, which is safe here: they are
# validated above to letters, digits, and [_./-], none of which awk escape
# processing touches.
CHECK_FROM_BUILD_ARGS="$BUILD_ARGS" CHECK_FROM_BUILD_CONTEXTS="$BUILD_CONTEXTS" CHECK_FROM_MIRROR="$MIRROR" LC_ALL=C awk \
  -v platform_set="$PLATFORM_SET" -v tplat="$T_PLAT" -v tos="$T_OS" \
  -v tarch="$T_ARCH" -v tvar="$T_VAR" -v bplat="$B_PLAT" -v bos="$B_OS" \
  -v barch="$B_ARCH" -v bvar="$B_VAR" -v target_set="$TARGET_SET" \
  -v target_stage="$TARGET_STAGE" '
# rtrim_c trims only what BuildKit ignores before its continuation check
# (\r from CRLF, then spaces and tabs); ltrim matches BuildKit trimming
# any leading whitespace before the comment and blank-line checks.
function rtrim_c(s) { sub(/\r$/, "", s); sub(/[ \t]+$/, "", s); return s }
function ltrim(s)   { sub(WSL, "", s); return s }

function fail(msg) { print "check-from-lines: " msg; EXITCODE = 1; exit 1 }

# BuildKit sets the automatic platform arguments on every build, so a FROM
# resolution that reads one is checkable only when the gate knows the
# platform (or, for TARGETSTAGE, the build target). A name that was seeded,
# declared with a default, or overridden is in ARGS and needs no check.
function autofail(name, lineno) {
  if (name in ARGS || !(name in AUTO)) return
  if (name == "TARGETSTAGE")
    fail("line " lineno " reads the automatic argument TARGETSTAGE, which BuildKit sets to the target stage name on every build. Pass --target so the gate resolves the same value the build does")
  fail("line " lineno " reads the automatic platform argument " name ", which BuildKit sets on every build. Pass --platform (and --build-platform when the build platform differs from the target) so the gate resolves the same file the builder does")
}

# Resolve one variable name. In "from" mode an unknown name is collected in
# UNRESOLVED instead of guessed at; in "default" mode it expands to the empty
# string, matching the builder.
function lookup(name, mode, lineno) {
  autofail(name, lineno)
  if (name in ARGS) return ARGS[name]
  if (mode == "from") UNRESOLVED = UNRESOLVED " " name
  return ""
}

# Expand $NAME, ${NAME}, ${NAME:-default}, ${NAME:+alt} in s. Any other
# modifier is rejected with exit 1 naming the expression: expanding it to an
# empty string could silently change the registry being checked.
function expand_str(s, mode, lineno,   out, j, k, name, c, mod, word, isset) {
  out = ""
  while (length(s) > 0) {
    j = index(s, "$")
    if (j == 0) { out = out s; break }
    out = out substr(s, 1, j - 1)
    s = substr(s, j + 1)
    if (substr(s, 1, 1) == "{") {
      s = substr(s, 2)
      if (!match(s, /^[A-Za-z_][A-Za-z0-9_]*/))
        fail("bad substitution \"${" s "\" at line " lineno)
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      c = substr(s, 1, 1)
      if (c == "}") {
        s = substr(s, 2)
        out = out lookup(name, mode, lineno)
      } else if (c == ":") {
        mod = substr(s, 2, 1)
        if (mod != "-" && mod != "+")
          fail("unsupported modifier in \"${" name ":" mod "...}\" at line " lineno ": only ${NAME}, ${NAME:-default} and ${NAME:+alt} are supported")
        k = index(s, "}")
        if (k == 0)
          fail("missing } in \"${" name s "\" at line " lineno)
        word = substr(s, 3, k - 3)
        s = substr(s, k + 1)
        if (word ~ /[${}"]/ || index(word, SQ) > 0 || index(word, ESC) > 0)
          fail("unsupported nested expansion in \"${" name ":" mod word "}\" at line " lineno)
        autofail(name, lineno)
        isset = (name in ARGS && ARGS[name] != "")
        if (mod == "-") out = out (isset ? ARGS[name] : word)
        else            out = out (isset ? word : "")
      } else if (c == "") {
        fail("missing } in \"${" name "\" at line " lineno)
      } else {
        fail("unsupported variable modifier in \"${" name c "...}\" at line " lineno ": only ${NAME}, ${NAME:-default} and ${NAME:+alt} are supported")
      }
    } else if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      out = out lookup(name, mode, lineno)
    } else {
      out = out "$"
    }
  }
  return out
}

# norm_ref(r): normalize an image reference or stage name the way docker
# reference normalization does before BuildKit matches it against a named
# build context, each rule pinned by an outline run (the named-contexts
# fixtures record the runs). The part before the first / is a registry
# host only when it contains a dot or a colon, is exactly localhost, or
# is not all-lowercase (splitDockerDomain treats a dotless first
# component with an uppercase letter as a domain: Foo/bar is domain Foo,
# path bar, pinned by an outline run where a byte-identical context
# matches it); the host keeps its case and compares byte-exact (a
# DOCKER.io context does not match a docker.io FROM, also pinned);
# index.docker.io maps to docker.io only in that exact lowercase
# spelling; a docker.io path without a slash gains library/; a reference
# with neither tag nor digest gains :latest; a digest part is kept
# verbatim. Returns the empty string for a value docker refuses (an
# uppercase repository, whitespace, empty parts, a colon inside the
# path). BuildKit fails any build whose FROM needs such a value and
# buildx refuses such a context name, so an empty result never silently
# matches.
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

function strip_quotes(s) {
  if (length(s) >= 2) {
    if (substr(s,1,1) == "\"" && substr(s,length(s),1) == "\"") return substr(s, 2, length(s)-2)
    if (substr(s,1,1) == SQ && substr(s,length(s),1) == SQ) return substr(s, 2, length(s)-2)
  }
  return s
}

# A heredoc delimiter this gate will trust: a plain name, or one pair of
# quotes around a plain name. Anything else returns "" and the caller
# rejects the construct instead of guessing how BuildKit lexes it.
function strict_heredoc_name(s,   q, inner) {
  if (s ~ /^[A-Za-z0-9_.-]+$/) return s
  q = substr(s, 1, 1)
  if ((q == "\"" || q == SQ) && length(s) >= 3 && substr(s, length(s), 1) == q) {
    inner = substr(s, 2, length(s) - 2)
    if (inner ~ /^[A-Za-z0-9_.-]+$/) return inner
  }
  return ""
}

# Tokenize a logical heredoc-capable line into the words that the BuildKit
# heredoc scan sees. Unquoted whitespace (space, tab, CR, VT, FF) splits words;
# single quotes run to the closing quote; double quotes run to the closing
# quote, inside which a backslash escapes ", $ and backslash; an unquoted
# backslash escapes the next character; << glues the space, tab, or CR
# characters after it and the following characters into the same word.
# Quotes, escapes, and glued whitespace are kept in the word (BuildKit lexes
# them raw), so a << inside or after quoted text never starts a word. The
# escape character here is always backslash, whatever the escape directive
# says: BuildKit hardcodes it for heredoc scanning. ${...} is passed through
# literally in the forms ${NAME}, ${NAME:-word} and ${NAME:+word} with a
# plain word; every other form is rejected, because it could shift the
# word boundaries BuildKit computes (a word with whitespace splits the
# enclosing word) or error inside the BuildKit lexer, which then silently
# scans no heredocs on the line. Fills W[1..n] and returns n; fails the run on an unbalanced
# quote or a Unicode space character, which this byte-wise scan cannot split
# the way BuildKit does.
function lex_words(s, lineno, W,   n, i, len, c, w, inw, j, k, q, nc, inner) {
  for (j = 1; j <= N_USPACE; j++)
    if (index(s, USPACE[j]) > 0)
      fail("line " lineno " combines a heredoc-capable instruction with a Unicode space character; this gate cannot split its words the way BuildKit does. Use ASCII spaces on lines that open heredocs")
  n = 0; w = ""; inw = 0
  len = length(s); i = 1
  while (i <= len) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\r" || c == VT || c == FF) {
      if (inw) { n++; W[n] = w; w = ""; inw = 0 }
      i++
      continue
    }
    if (c == "\\") {
      # The pair stays in the word raw; an escaped quote opens nothing and
      # an escaped space splits nothing. A trailing backslash stays as-is.
      if (i == len) { w = w c; inw = 1; i++ }
      else { w = w c substr(s, i + 1, 1); inw = 1; i += 2 }
      continue
    }
    if (c == SQ) {
      j = index(substr(s, i + 1), SQ)
      if (j == 0)
        fail("unbalanced single quote on a heredoc-capable instruction at line " lineno ": this gate cannot tell where its words end (BuildKit scans no heredocs on such a line). Balance the quote")
      w = w substr(s, i, j + 1); inw = 1; i += j + 1
      continue
    }
    if (c == "\"") {
      w = w c; inw = 1; i++
      q = 0
      while (i <= len) {
        c = substr(s, i, 1)
        if (c == "\\") {
          nc = substr(s, i + 1, 1)
          if (nc == "\"" || nc == "$" || nc == "\\") { w = w c nc; i += 2 }
          else { w = w c; i++ }
          continue
        }
        if (c == "\"") { w = w c; i++; q = 1; break }
        if (c == "$" && substr(s, i + 1, 1) == "{") {
          k = lex_brace(s, i, lineno)
          w = w substr(s, i, k - i + 1); i = k + 1
          continue
        }
        w = w c; i++
      }
      if (!q)
        fail("unbalanced double quote on a heredoc-capable instruction at line " lineno ": this gate cannot tell where its words end (BuildKit scans no heredocs on such a line). Balance the quote")
      continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      k = lex_brace(s, i, lineno)
      w = w substr(s, i, k - i + 1); inw = 1; i = k + 1
      continue
    }
    if (c == "<" && substr(s, i + 1, 1) == "<") {
      # BuildKit glues space, tab, and CR after << into the same word, so
      # << NAME is one heredoc word; VT and FF are not glued and split it.
      w = w "<<"; inw = 1; i += 2
      while (i <= len) {
        c = substr(s, i, 1)
        if (c != " " && c != "\t" && c != "\r") break
        w = w c; i++
      }
      continue
    }
    w = w c; inw = 1; i++
  }
  if (inw) { n++; W[n] = w }
  return n
}

# Validate a ${...} expansion starting at position i of s (s[i] is the $)
# on a heredoc-capable line and return the position of its closing brace.
# Only ${NAME}, ${NAME:-word} and ${NAME:+word} with a word free of
# whitespace, quotes, backslashes, <, $ and { pass; anything else could
# change how BuildKit splits the line into words, or error inside its
# lexer, so the gate refuses to guess.
function lex_brace(s, i, lineno,   k, inner, ok) {
  k = index(substr(s, i + 2), "}")
  if (k == 0)
    fail("missing } in a ${ expansion on a heredoc-capable instruction at line " lineno)
  inner = substr(s, i + 2, k - 1)
  ok = 0
  if (inner ~ /^[A-Za-z_][A-Za-z0-9_]*$/) ok = 1
  else if (inner ~ /^[A-Za-z_][A-Za-z0-9_]*:[-+][^ \t\r"\\<$]*$/ &&
           index(inner, SQ) == 0 && index(inner, VT) == 0 && index(inner, FF) == 0)
    ok = 1
  if (!ok)
    fail("the expansion \"${" inner "}\" at line " lineno " is not supported on a heredoc-capable instruction: only ${NAME}, ${NAME:-word} and ${NAME:+word} with a plain word can be split into words the way BuildKit does. Rewrite the expansion or move it off the line that opens the heredoc")
  return i + 1 + k
}

# Detect the heredocs a logical RUN/COPY/ADD (or ONBUILD thereof) line opens,
# in order, from its lexed words, mirroring the BuildKit per-word test
# (^digits<<, optional -, optional glued whitespace, then a delimiter with no
# further <): <<EOF, <<-EOF, quoted forms, 2<<EOF, and the separated << EOF
# all carry their name inside one word; <<- NAME with a space is not a
# heredoc (the dash blocks the whitespace glue), and neither is a bare << at
# end of line or a rest containing another < character.
function scan_heredocs(W, n, lineno,   i, t, body, chomp, name) {
  for (i = 1; i <= n; i++) {
    t = W[i]
    if (t !~ /^[0-9]*<</) continue
    body = t
    sub(/^[0-9]*<</, "", body)
    chomp = 0
    if (substr(body, 1, 1) == "-") { chomp = 1; body = substr(body, 2) }
    else sub(/^[ \t\r]+/, "", body)   # whitespace glued by the lexer
    if (body == "") continue           # bare <<, <<- or fd<<: not a heredoc
    if (index(body, "<") > 0) continue # not a heredoc to BuildKit either
    name = strict_heredoc_name(body)
    if (name == "")
      fail("heredoc marker \"" t "\" at line " lineno " is not supported by this gate: the delimiter could not be classified with certainty, so the following lines cannot be told apart from instructions. Use a plain <<NAME heredoc")
    HD_N++; HD_NAME[HD_N] = name; HD_CHOMP[HD_N] = chomp
  }
}

BEGIN {
  SQ = sprintf("%c", 39)   # single quote, kept out of the awk source for portability
  VT = sprintf("%c", 11)
  FF = sprintf("%c", 12)
  BOM = sprintf("%c%c%c", 239, 187, 191)
  # Word splitting and leading-whitespace trimming match BuildKit, which
  # treats vertical tab and form feed as separators too.
  WS  = sprintf("[ \t\r%c%c]+", 11, 12)
  WSL = "^" WS
  CTRL_WS = sprintf("[%c%c\r]", 11, 12)
  ESC = "\\"
  # The UTF-8 byte sequences of the Unicode space characters the BuildKit
  # heredoc lexer splits words on beyond ASCII (unicode.IsSpace): NEL, NBSP,
  # OGHAM SPACE MARK, EN QUAD through HAIR SPACE, LINE SEPARATOR, PARAGRAPH
  # SEPARATOR, NARROW NBSP, MEDIUM MATHEMATICAL SPACE, IDEOGRAPHIC SPACE.
  # The gate runs awk under LC_ALL=C so these build and compare bytewise.
  N_USPACE = 0
  USPACE[++N_USPACE] = sprintf("%c%c", 194, 133)
  USPACE[++N_USPACE] = sprintf("%c%c", 194, 160)
  USPACE[++N_USPACE] = sprintf("%c%c%c", 225, 154, 128)
  for (u = 128; u <= 138; u++)
    USPACE[++N_USPACE] = sprintf("%c%c%c", 226, 128, u)
  USPACE[++N_USPACE] = sprintf("%c%c%c", 226, 128, 168)
  USPACE[++N_USPACE] = sprintf("%c%c%c", 226, 128, 169)
  USPACE[++N_USPACE] = sprintf("%c%c%c", 226, 128, 175)
  USPACE[++N_USPACE] = sprintf("%c%c%c", 226, 129, 159)
  USPACE[++N_USPACE] = sprintf("%c%c%c", 227, 128, 128)
  seen_from = 0
  buf = ""; bufline = 0
  directive_mode = 1
  HD_N = 0; HD_I = 1
  # The same normalization check-from-oracle.sh applies to its mirror:
  # lowercase, strip trailing slashes, trim spaces and tabs, in that order.
  mirror = tolower(ENVIRON["CHECK_FROM_MIRROR"])
  sub(/\/+$/, "", mirror)
  sub(/^[ \t]+/, "", mirror); sub(/[ \t]+$/, "", mirror)
  n_ba = split(ENVIRON["CHECK_FROM_BUILD_ARGS"], ba_lines, "\n")
  for (b = 1; b <= n_ba; b++) {
    if (ba_lines[b] == "") continue
    p = index(ba_lines[b], "=")
    if (p > 1) OVERRIDE[substr(ba_lines[b], 1, p - 1)] = substr(ba_lines[b], p + 1)
  }
  # Named build contexts, keyed by the normalized name; BuildKit matches a
  # context against a FROM reference or a stage name after reference
  # normalization on both sides, and a repeated flag with the same name
  # wins with its last value, both pinned by outline runs. A name docker
  # cannot parse is refused here because buildx refuses the invocation
  # (verified; it names the context and the lowercase repository rule).
  N_CTX = 0
  n_bc = split(ENVIRON["CHECK_FROM_BUILD_CONTEXTS"], bc_lines, "\n")
  for (b = 1; b <= n_bc; b++) {
    if (bc_lines[b] == "") continue
    p = index(bc_lines[b], "=")
    if (p <= 1) continue
    cname = substr(bc_lines[b], 1, p - 1)
    cnorm = norm_ref(cname)
    if (cnorm == "")
      fail("the build context name \"" cname "\" is not a valid image reference, so buildx refuses this invocation; the captured build cannot run with it")
    CTX[cnorm] = substr(bc_lines[b], p + 1)
    N_CTX++
  }
  # Seed the automatic platform arguments the way BuildKit does: all of them
  # when the platform is known (the OSVERSION pair and a missing variant are
  # set to the empty string, which the :- and :+ modifiers treat as unset),
  # TARGETSTAGE when the target is known, and a --build-arg override on any
  # of these names regardless, declaration or not, matching docker build.
  n_auto = split("TARGETPLATFORM TARGETOS TARGETARCH TARGETVARIANT TARGETOSVERSION TARGETSTAGE BUILDPLATFORM BUILDOS BUILDARCH BUILDVARIANT BUILDOSVERSION", auto_names, " ")
  for (b = 1; b <= n_auto; b++) AUTO[auto_names[b]] = 1
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
}

{
  raw = $0
  if (NR == 1 && substr(raw, 1, 3) == BOM) raw = substr(raw, 4)

  # Heredoc content: raw lines up to each pending delimiter, in order, are
  # file content, never instructions, comments, or continuations.
  if (HD_N > 0 && HD_I <= HD_N) {
    t = raw
    sub(/\r$/, "", t)
    if (HD_CHOMP[HD_I]) sub(/^\t+/, "", t)
    if (t == HD_NAME[HD_I]) {
      HD_I++
      if (HD_I > HD_N) { HD_N = 0; HD_I = 1 }
    }
    next
  }

  line = rtrim_c(raw)
  trimmed = ltrim(line)

  # Parser directives: only at the top of the file; the block ends at the
  # first line that is not a known "# key=value" directive.
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
        if (dkey in SEEN_DIRECTIVE)
          fail("only one " dkey " parser directive can be used (line " NR ")")
        SEEN_DIRECTIVE[dkey] = 1
        if (dkey == "escape") {
          if (dval != "\\" && dval != "`")
            fail("invalid escape directive value " SQ dval SQ " at line " NR ": must be \\ or ` (BuildKit rejects this file too)")
          ESC = dval
        } else if (dkey == "syntax") {
          # Only the rolling tag, byte for byte. A pinned tag parses by the
          # pin, not by the rules this gate implements (BuildKit under
          # docker/dockerfile:1.0 treats a heredoc body as ordinary
          # instructions, so a FROM inside it is a real FROM), buildx can
          # answer --call=outline for a pinned frontend through a different
          # subrequest-capable frontend, and BuildKit itself rejects an
          # uppercase spelling such as Docker/Dockerfile:1 as an invalid
          # reference.
          if (dval != "docker/dockerfile:1" && dval != "docker.io/docker/dockerfile:1")
            fail("syntax directive " SQ dval SQ " at line " NR " selects a frontend whose parsing rules this gate cannot verify; only the rolling docker/dockerfile:1 tag (an optional docker.io/ prefix allowed) is supported")
        }
        next
      }
      directive_mode = 0   # unknown key: the line is a comment and ends the block
    } else {
      directive_mode = 0
    }
  }

  # Comment lines and blank lines are dropped entirely, even inside a
  # continuation, matching the Dockerfile parser (a blank line inside a
  # continuation draws a BuildKit warning but the instruction continues).
  if (trimmed ~ /^#/) next
  if (trimmed == "") next
  if (buf == "") bufline = NR
  # A line continues when its last non-whitespace character is the escape
  # character and the one before is not also the escape character; the
  # escape character is stripped and the lines are joined with no separator,
  # exactly as BuildKit joins them.
  llen = length(line)
  if (substr(line, llen, 1) == ESC && (llen == 1 || substr(line, llen - 1, 1) != ESC)) {
    buf = buf substr(line, 1, llen - 1)
    next
  }
  buf = buf line
  logical = ltrim(buf); buf = ""
  process(logical, bufline)
}

END {
  if (EXITCODE) exit EXITCODE
  if (buf != "") process(ltrim(buf), bufline)
  if (EXITCODE) exit EXITCODE
  if (HD_N > 0 && HD_I <= HD_N)
    fail("unterminated heredoc (delimiter \"" HD_NAME[HD_I] "\" never appeared; BuildKit rejects this file too)")
  exit EXITCODE + 0
}

function process(logical, lineno,   n, f, instr, sub2, p, q, ref, resolved, alias, lc, i, ai, t, name, val, inner, litq, cnorm, anorm, csrc, checked, lc2, LEXW, ln) {
  n = split(logical, f, WS)
  if (n == 0) return
  instr = toupper(f[1])

  # Heredoc scanning lexes the whole logical line, as BuildKit does, so a
  # marker is recognized only where its << starts an unquoted word.
  if (instr == "RUN" || instr == "COPY" || instr == "ADD") {
    if (index(logical, "<<") > 0) {
      ln = lex_words(logical, lineno, LEXW)
      scan_heredocs(LEXW, ln, lineno)
    }
    return
  }
  if (instr == "ONBUILD" && n >= 2) {
    sub2 = toupper(f[2])
    if ((sub2 == "RUN" || sub2 == "COPY" || sub2 == "ADD") && index(logical, "<<") > 0) {
      ln = lex_words(logical, lineno, LEXW)
      scan_heredocs(LEXW, ln, lineno)
    }
    return
  }

  if (instr == "ARG" && !seen_from) {
    # Every assignment token on the line counts, matching docker build. A
    # --build-arg override beats the declared default, and gives a value to
    # an ARG declared with none. An override with no matching ARG
    # declaration never applies, also matching docker build.
    for (ai = 2; ai <= n; ai++) {
      t = f[ai]
      if (index(t, ESC) > 0)
        fail("ARG at line " lineno " contains the escape character in \"" t "\"; escaped whitespace in ARG values is not supported by this gate. Write the value without escapes")
      p = index(t, "=")
      if (p == 0) {
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (t in OVERRIDE)) ARGS[t] = OVERRIDE[t]
        continue
      }
      if (p == 1)
        fail("ARG at line " lineno " declares an assignment with an empty name (\"" t "\")")
      name = substr(t, 1, p - 1)
      val = substr(t, p + 1)
      # A declared default for an automatic argument name is rejected, not
      # emulated. BuildKit lets the declared default beat the automatic
      # value while a --build-arg beats the default, and the oracle gate
      # can pass a platform only as --build-arg overrides, so a default
      # here would make the oracle check a different file than the build
      # resolves. A bare redeclaration (ARG TARGETARCH) stays allowed.
      if (name in AUTO)
        fail("ARG at line " lineno " declares a default for the automatic argument " name ". The FROM gate passes the platform as --build-arg overrides, which beat a declared default where the automatic value would lose to it, so the gate cannot check this file the way the build resolves it. Redeclare it bare (ARG " name ") or use another name")
      litq = 0
      if (index(val, "\"") > 0 || index(val, SQ) > 0) {
        q = substr(val, 1, 1)
        inner = substr(val, 2, length(val) - 2)
        if ((q != "\"" && q != SQ) || length(val) < 2 || substr(val, length(val), 1) != q || index(inner, q) > 0)
          fail("ARG at line " lineno " has a quoted value this gate cannot take apart (\"" t "\"): a quoted value spanning whitespace or a stray quote is not supported. Quote the whole value or none of it")
        val = inner
        # BuildKit keeps a single-quoted default literal (verified with an
        # outline run; the value ${UNSET} survives as those seven
        # characters), where a double-quoted or unquoted default expands.
        if (q == SQ) litq = 1
      }
      if (name in OVERRIDE) ARGS[name] = OVERRIDE[name]
      else if (litq) ARGS[name] = val
      else ARGS[name] = expand_str(val, "default", lineno)
    }
    return
  }

  if (instr != "FROM") return
  seen_from = 1

  # Skip flags (--platform=... etc.) to reach the image ref.
  i = 2
  while (i <= n && substr(f[i], 1, 2) == "--") i++
  if (i > n)
    fail("FROM at line " lineno " has no image reference")
  # After the flags, exactly one image reference, optionally followed by AS
  # and a stage name. BuildKit fails every other token count, including
  # three tokens whose middle one is not AS, with "FROM requires either one
  # or three arguments", so extra tokens this gate would otherwise ignore
  # can never hide a reference from it.
  if (n - i != 0 && !(n - i == 2 && toupper(f[i + 1]) == "AS"))
    fail("FROM at line " lineno " (\"" logical "\") does not have exactly one image reference plus an optional AS name; BuildKit fails such a line with \"FROM requires either one or three arguments\"")
  ref = f[i]

  UNRESOLVED = ""
  resolved = expand_str(ref, "from", lineno)
  if (UNRESOLVED != "")
    fail("FROM \"" ref "\" at line " lineno " has unresolved ARG variable(s):" UNRESOLVED ". Declare a default before the first FROM or remove the interpolation")
  if (resolved == "") resolved = ref

  alias = ""
  if (i + 2 <= n && toupper(f[i + 1]) == "AS") {
    alias = f[i + 2]
    if (alias !~ /^[a-zA-Z][a-zA-Z0-9_.-]*$/)
      fail("FROM stage alias \"" alias "\" at line " lineno " is not allowed: aliases must match ^[a-zA-Z][a-zA-Z0-9_.-]*$ (Docker stage-name rules)")
    alias = tolower(alias)
  }

  # A context whose name matches the AS name of this stage applies at the
  # stage definition, replacing the base of the stage even when no FROM
  # references the name, with reference normalization on the name (a docker.io/library/
  # spelling matches a bare stage name) and case-insensitively on the
  # alias, and it beats a context matching the base reference and a
  # scratch base alike; each rule pinned by an outline run (the scratch
  # replacement by a real cacheonly build too). The base as written is
  # never pulled, so the context source stands in for it entirely.
  if (alias != "" && N_CTX > 0) {
    anorm = norm_ref(alias)
    if (anorm != "" && (anorm in CTX)) {
      csrc = CTX[anorm]
      if (substr(csrc, 1, 15) != "docker-image://")
        fail("the stage \"" alias "\" at line " lineno " is overridden by a --build-context whose source (" csrc ") is not a docker-image:// reference. BuildKit builds the stage from that source in place of its base, and a base taken from a local directory, a git repository, an oci layout, or another build target cannot be checked against the allowlist, so a named context of that kind is unsupported for a stage name")
      checked = substr(csrc, 16)
      lc2 = tolower(checked)
      ok = 0
      if (substr(lc2, 1, 8) == "cgr.dev/") ok = 1
      else if (mirror != "" && substr(lc2, 1, length(mirror) + 1) == mirror "/") ok = 1
      if (!ok)
        fail("the stage \"" alias "\" at line " lineno " (base \"" resolved "\") is overridden by --build-context to \"" checked "\", which is not allowed: base images must come from cgr.dev/* or the configured external mirror")
      ALIASES[alias] = 1
      return
    }
  }

  lc = tolower(resolved)
  ok = 0
  # scratch case-sensitively: BuildKit gives the empty base only for the
  # lowercase spelling and rejects FROM SCRATCH as an image reference whose
  # repository name must be lowercase. scratch comes before the context
  # check because a named context cannot override scratch (pinned by a
  # real build), and the context check comes before the alias table
  # because a context beats a stage of the same name (also pinned).
  if (resolved == "scratch") ok = 1
  else {
    if (N_CTX > 0) {
      cnorm = norm_ref(resolved)
      if (cnorm != "" && (cnorm in CTX)) {
        csrc = CTX[cnorm]
        if (substr(csrc, 1, 15) != "docker-image://")
          fail("FROM \"" resolved "\" at line " lineno " is overridden by a --build-context whose source (" csrc ") is not a docker-image:// reference. A base taken from a local directory, a git repository, an oci layout, or another build target cannot be checked against the allowlist, so a named context of that kind is unsupported for a base")
        checked = substr(csrc, 16)
        lc2 = tolower(checked)
        if (substr(lc2, 1, 8) == "cgr.dev/") ok = 1
        else if (mirror != "" && substr(lc2, 1, length(mirror) + 1) == mirror "/") ok = 1
        if (!ok)
          fail("FROM \"" resolved "\" at line " lineno " is overridden by --build-context to \"" checked "\", which is not allowed: base images must come from cgr.dev/* or the configured external mirror")
      }
    }
    if (!ok) {
      if (lc in ALIASES) ok = 1
      else if (substr(lc, 1, 8) == "cgr.dev/") ok = 1
      else if (mirror != "" && substr(lc, 1, length(mirror) + 1) == mirror "/") ok = 1
    }
  }

  if (!ok)
    fail("FROM \"" resolved "\" at line " lineno " is not allowed: base images must come from cgr.dev/* or the configured external mirror")

  if (alias != "") ALIASES[alias] = 1
}
' < "$DOCKERFILE"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "check-from-lines: OK — every FROM in $DOCKERFILE is on the allowlist"
fi
exit "$rc"
