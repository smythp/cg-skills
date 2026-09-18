#!/bin/sh
# check-from-lines.sh — read every FROM in a Dockerfile textually and check
# each against the migration allowlist: cgr.dev/* (exact host boundary), the
# configured external mirror prefix (on a / boundary), scratch, and
# previously declared stage aliases.
#
# Posture. The FROM gate exists to catch mistakes in a migration. It is
# not a guarantee that a Dockerfile written to defeat it cannot pass, and
# it does not try to lock down every rare way to specify an image. This
# check advises; BuildKit's own resolution, asked by check-from-oracle.sh,
# decides. Findings come in two classes:
#   - REJECTED (exit 1): a base known to resolve outside the allowlist.
#     The resolution rules below were each verified against BuildKit, so a
#     REJECTED base is one the build really pulls off the allowlist: a FROM
#     whose resolved reference BuildKit accepts and the allowlist does not,
#     a stage alias shaped like an image reference (the alias table decides
#     what later FROMs mean, so an alias this check cannot trust as a name
#     is refused), and a named build context whose docker-image:// source
#     is off the allowlist, at a FROM or at a stage definition.
#   - UNVERIFIED (exit 3): a construct this check cannot verify textually.
#     Each is reported on its own line naming the construct and the line,
#     the scan continues where its line classification stays trustworthy so
#     every such construct is listed, and the oracle decides what the build
#     resolves. Nothing UNVERIFIED passes silently, and nothing UNVERIFIED
#     is refused on a guess.
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
# Exit codes: 0 = every FROM verified and on the allowlist; 1 = a base
# known to be off the allowlist (REJECTED), with a message naming the line;
# 2 = usage error, including a --build-context name buildx itself refuses;
# 3 = no known off-allowlist base, but constructs this check could not
# verify (the UNVERIFIED lines name them; check-from-oracle.sh decides
# them).
#
# Semantics ported from Guardener's static validator and checked against
# BuildKit (the parser rules below were each verified against
# docker buildx build --call=outline on the builtin Dockerfile frontend):
#   - Physical lines: a NUL byte anywhere in the file, and a CR that is not
#     immediately followed by LF, are reported as UNVERIFIED before parsing,
#     naming the line, and the file is not scanned further. BuildKit keeps
#     both bytes inside the surrounding line where this parser would split
#     it (its FROM reproductions fail with "FROM requires either one or
#     three arguments"), awk implementations disagree about NUL bytes in
#     input, and once the file is split into records a final CR with no LF
#     cannot be told apart from a CRLF ending, so nothing after such a byte
#     can be classified with certainty. CRLF line endings are accepted as
#     before.
#   - Parser directives: consecutive '# key=value' lines from the top of the
#     file (leading whitespace and a UTF-8 BOM allowed, keys case-insensitive).
#     The block ends at the first line that is not a known directive (a
#     plain comment, a blank line, an unknown key, or an instruction). '# escape=' is
#     honored for backslash and backtick; any other value is UNVERIFIED
#     (BuildKit itself errors on it; this check keeps the previous escape
#     character and continues). A duplicate directive is UNVERIFIED the same
#     way, keeping the first value. A line in directive position whose shape
#     is '# key=value' with a key this check does not know is UNVERIFIED and
#     is then read as the comment the rolling frontend reads it as, ending
#     the block. '# syntax=' is verified only when its value is exactly
#     docker/dockerfile:1 or docker.io/docker/dockerfile:1, the rolling tag
#     of the frontend these rules were checked against; any other value is
#     UNVERIFIED naming the frontend, because a pinned tag parses by the
#     pin's rules, not the rolling frontend's (under docker/dockerfile:1.0
#     a heredoc body is ordinary instructions). The scan then continues
#     under the rolling rules as a best effort, and check-from-oracle.sh
#     runs the pinned frontend itself and decides.
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
#     cannot split with certainty is UNVERIFIED rather than guessed at. An
#     unbalanced quote is reported and the line opens no heredoc, which is
#     what BuildKit does (its lexer errors and it silently scans no heredocs
#     on such a line), so the scan continues. A ${...} expansion on a
#     heredoc-capable line in any form other than ${NAME}, ${NAME:-word} or
#     ${NAME:+word} with a plain word (other forms can shift BuildKit's word
#     boundaries or disable its heredoc scan entirely), and a Unicode space
#     character on such a line (BuildKit splits words on those; this
#     byte-wise scan cannot), leave the heredoc extent unknown: every line
#     after them could be content or instruction, so the report names the
#     construct and the scan stops there. The
#     content lines up to and including the line equal to each delimiter, in
#     order, are file content, not instructions and not comments; for <<-
#     the delimiter comparison strips leading tabs; otherwise the comparison
#     is exact, so a delimiter line with trailing whitespace does not
#     terminate. A heredoc marker this check cannot classify with certainty
#     (a quoted name spanning whitespace, a name containing a quote, $, a
#     backslash, or other unusual characters) is UNVERIFIED and stops the
#     scan the same way, and an unterminated heredoc is UNVERIFIED
#     (BuildKit rejects the file).
#   - ARG lines before the first FROM: every NAME=value assignment on the
#     line is processed, matching docker build, not just the first. A value
#     may be wrapped in one pair of quotes; a single-quoted value is kept
#     literally, with no variable expansion inside it, as BuildKit keeps it
#     (verified with an outline run), while double-quoted and unquoted
#     values expand. A quoted value spanning whitespace, a stray quote, an
#     escape character, or an empty name in any token is UNVERIFIED rather
#     than reassembled, and it leaves the whole ARG table untrustworthy:
#     BuildKit reassembles such a line by rules this check does not model
#     (verified with real builds: ARG A="x y" B=alpine assigns B, while
#     ARG OTHER=a\ B=alpine swallows B= into OTHER's value), so every later
#     FROM whose resolution reads any variable is UNVERIFIED too, a
#     variable an earlier line assigned included (the unverifiable line
#     could have reassigned it, so the earlier value is stale), while a
#     FROM written as a literal reference stays verifiable. ARGs declared
#     after a FROM are ignored for FROM resolution. A --build-arg override
#     replaces the default of a matching ARG declared before the first
#     FROM, and gives a value to a global ARG declared with no default. An
#     override whose name no ARG declares is ignored, as in docker build,
#     so through an unverifiable ARG line an overridden name stays certain
#     only when a trusted line already declared it, and the override value
#     wins; a name declared only on the unverifiable line, or not yet
#     declared, is uncertain like every other name until a trusted ARG
#     declares it (each verified with real builds: with the override for
#     BASE, an earlier trusted declaration resolves the override value,
#     while ARG OTHER="x BASE=y" alone never declares BASE and the
#     override does not apply). A
#     global ARG that declares a default for one of the automatic argument
#     names replaces the automatic value, and a --build-arg override beats
#     the declared default, exactly as BuildKit applies them (each verified
#     with a real build; see the automatic arguments bullet).
#   - Variable expansion supports $NAME, ${NAME}, ${NAME:-default} (default
#     when unset or empty) and ${NAME:+alt} (alt when set and non-empty),
#     with BuildKit's semantics. Every other modifier (%, #, /, ^, and the
#     colon-less - and + forms) is UNVERIFIED naming the expression, never
#     expanded to an empty string; a value it touches is unknown from then
#     on, and a FROM that reads such a value is UNVERIFIED too.
#   - FROM flags such as --platform=... are skipped to reach the image ref.
#     After the flags, a FROM has exactly one image reference, optionally
#     followed by AS and a stage name; any other token count is UNVERIFIED
#     quoting the line, because BuildKit fails such a line with "FROM
#     requires either one or three arguments" (a middle token other than AS
#     draws the same message), so no base pulls from it. scratch is matched
#     case-sensitively; BuildKit treats only the lowercase spelling as the
#     empty base and rejects FROM SCRATCH as an invalid reference
#     (repository names must be lowercase), so any other spelling that is
#     not a reference BuildKit accepts is UNVERIFIED, and one it accepts is
#     checked against the allowlist like any reference.
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
#     seeded value, and a global declaration that gives one of these names a
#     default replaces the seeded value, while a --build-arg override beats
#     both, exactly as BuildKit applies them (declared default over
#     automatic value, --build-arg over declared default, each verified
#     with a real build, TARGETSTAGE against --target included).
#     When --platform was not given and FROM resolution
#     reads one of these names, the FROM is UNVERIFIED naming the argument
#     and asking for --platform (or --target, for TARGETSTAGE), because
#     BuildKit resolves a value this check does not know. A file that never
#     reads them behaves as before.
#   - A variable in a FROM ref that no global ARG and no override gives a
#     value expands to the empty string, exactly as BuildKit expands it
#     (verified with real builds: FROM alpine${UNSET} resolves
#     docker.io/library/alpine, and an override without a declaration never
#     applies, so the captured invocation fixes the value). The expanded
#     reference is then classified like any other. A FROM whose whole
#     reference expands empty is UNVERIFIED naming the empty result,
#     because BuildKit refuses an empty base (base name should not be
#     blank, verified), so no base pulls from it as written.
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
#     outline run or a real build. The check applies the same matching at
#     each FROM and at each AS name. A matching docker-image://REF source
#     puts REF through the allowlist in place of the FROM (or of the
#     overridden stage's base), after checking that REF is a reference
#     docker accepts: an empty or invalid REF is UNVERIFIED naming it,
#     because buildx accepts the flag and the build then fails on it
#     (invalid reference format, verified with an empty reference and with
#     alpine:--), so no base pulls from it; a matching source of any other kind (a
#     local directory, a git repository, an oci layout, another target) is
#     UNVERIFIED, because a base built from such a source has no registry
#     reference to check; a name that matches nothing is ignored. A context
#     name that is not a valid reference is a usage error (exit 2): buildx
#     refuses the invocation, so the captured build cannot run with it.
#   - A stage alias must match ^[a-zA-Z][a-zA-Z0-9_.-]*$ (Docker stage-name
#     rules) so an image-shaped alias cannot become a trusted name for later
#     FROMs; an alias outside that shape is REJECTED, because the alias
#     table decides what every later FROM in the file means. Aliases compare
#     case-insensitively.
#   - A FROM naming a stage that is declared later in the file is a stage
#     reference to BuildKit, which resolves stage names anywhere in the
#     file, never a pull (verified with an outline run). This check reads
#     the file top to bottom and trusts only aliases already declared, so a
#     forward reference is UNVERIFIED, decided at the end of the scan when
#     every stage name is known: a bare name matching no stage anywhere is
#     a pull and meets the allowlist (REJECTED off it), a name only a later
#     stage declares is reported, and a stage is never its own base, so
#     FROM alpine AS alpine pulls alpine (verified with a real run).
#   - Lookalike hosts (cgr.dev.evil.example.com) and mirror prefix siblings
#     (mirror-extra/...) are rejected by the boundary checks.
#
# What UNVERIFIED covers, in one list: the modifiers beyond ${NAME:-default}
# and ${NAME:+alt}, quoted or escaped whitespace and empty names in ARG
# tokens, ambiguous heredoc markers, unbalanced quotes and restricted
# ${...} forms and Unicode spaces on heredoc-capable lines, unterminated
# heredocs, pinned '# syntax=' frontends, unknown or duplicate parser
# directives and invalid escape values, NUL bytes and lone CRs, FROM token
# counts BuildKit refuses, references BuildKit refuses (an invalid tag,
# digest, path component, or registry host included), a FROM whose
# reference expands to the empty string,
# automatic platform arguments read without
# --platform or --target, forward stage references, and named build
# contexts whose source is not docker-image:// or whose docker-image://
# reference BuildKit refuses. None of these is emulated
# or guessed at; each is named for the report, and check-from-oracle.sh
# decides them with BuildKit's own resolution. One documented deviation
# stays: with --platform but no --build-platform the BUILD* arguments take
# the target platform's values, which matches every same-platform build
# but differs on a cross-platform one until the caller passes
# --build-platform.
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
      echo "check-from-lines: UNVERIFIED line ${BAD_BYTE#* } contains a NUL byte; this check cannot split such a line the way BuildKit does, so the file is reported instead of scanned. check-from-oracle.sh decides what the build resolves"
      ;;
    *)
      echo "check-from-lines: UNVERIFIED line ${BAD_BYTE#* } contains a CR that is not part of a CRLF line ending; this check cannot split such a line the way BuildKit does, so the file is reported instead of scanned (CRLF endings are accepted). check-from-oracle.sh decides what the build resolves"
      ;;
  esac
  exit 3
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

# hard: a base known to resolve outside the allowlist; the scan stops.
# warn: a construct this check cannot verify; the line is reported and the
# scan continues where its line classification stays trustworthy.
# warn_halt: an unverifiable construct after which no line can be told
# apart from heredoc content, so the scan stops with the report so far.
function hard(msg) { print "check-from-lines: REJECTED: " msg; EXITCODE = 1; exit 1 }
function warn(msg) { print "check-from-lines: UNVERIFIED " msg; WARNED++ }
function warn_halt(msg) {
  warn(msg)
  print "check-from-lines: the lines after this construct cannot be told apart from heredoc content, so the scan stops here; check-from-oracle.sh decides the rest of the file"
  HALT = 1
  exit
}

# BuildKit sets the automatic platform arguments on every build, so a FROM
# resolution that reads one is checkable only when this check knows the
# platform (or, for TARGETSTAGE, the build target). A name that was seeded,
# declared with a default, or overridden is in ARGS and needs no check; a
# read this check cannot resolve marks the expansion uncertain.
function autocheck(name, lineno) {
  if (name in ARGS || !(name in AUTO)) return
  UNCERTAIN = 1
  if (name == "TARGETSTAGE")
    warn("line " lineno " reads the automatic argument TARGETSTAGE, which BuildKit sets to the target stage name on every build, and this run has no --target. Pass --target so the check resolves the same value the build does")
  else
    warn("line " lineno " reads the automatic platform argument " name ", which BuildKit sets on every build, and this run has no --platform. Pass --platform (and --build-platform when the build platform differs from the target) so the check resolves the same file the builder does")
}

# taint_args(): an unverifiable ARG line could have assigned any name that
# appears on it (BuildKit reassembles such a line by rules this check does
# not model), so every name loses its trusted value, the names earlier
# lines assigned included; ARG BASE=alpine followed by an unverifiable line
# reassigning BASE must not leave the stale alpine trusted (a real build
# of that shape assigns the later value, so a FROM reading BASE is
# unverified, never rejected on the stale value). Clearing CLEAN puts every
# name under the ARG_TAINT rule in unknown_var below. A name a trusted
# line already declared that carries a --build-arg override keeps its
# entry: the override beats any default the unverifiable line could have
# assigned (a real build of ARG BASE=alpine, then an unverifiable line
# reassigning BASE, then FROM ${BASE}base with the override resolves the
# override value), so its value stays certain.
function taint_args(   k) {
  ARG_TAINT = 1
  for (k in CLEAN) if (!(k in OVERRIDE)) delete CLEAN[k]
}

# unknown_var(name): true when this check lost track of the value of name.
# An unverifiable ARG line taints every name it could have assigned, which
# is any name (ARG_TAINT), the names earlier lines assigned included; a
# name assigned by a trusted line after the tainted one (CLEAN) is certain
# again, and a name whose own default could not be expanded stays unknown
# (ARGS_UNKNOWN). A --build-arg override applies only to a name the file
# declares with a global ARG (verified with real builds; see the ARG
# bullet in the header), so an override exempts a name from the taint only
# when a trusted line declared it, before the taint (taint_args keeps that
# entry) or after it, and the name then carries the override value; a name
# declared only on the unverifiable line, or not yet declared, is
# uncertain like every other name.
function unknown_var(name) {
  if (name in ARGS_UNKNOWN) return 1
  if (ARG_TAINT && !(name in CLEAN)) return 1
  return 0
}

# Resolve one variable name. An unknown name expands to the empty string,
# exactly as BuildKit expands a variable no global ARG and no override
# gives a value (verified with real builds); in "from" mode the name is
# also collected in UNRESOLVED so a reference that expands wholly empty
# can be reported naming what emptied it. A name whose value this check
# lost track of marks the expansion uncertain instead of answering.
function lookup(name, mode, lineno) {
  autocheck(name, lineno)
  if (unknown_var(name)) { UNCERTAIN = 1; return "" }
  if (name in ARGS) return ARGS[name]
  if (mode == "from") UNRESOLVED = UNRESOLVED " " name
  return ""
}

# Expand $NAME, ${NAME}, ${NAME:-default}, ${NAME:+alt} in s. Any other
# modifier is UNVERIFIED naming the expression, never expanded to an empty
# string, and it marks the expansion uncertain: the caller treats the value
# as unknown instead of checking a guess against the allowlist.
function expand_str(s, mode, lineno,   out, j, k, name, c, mod, word, isset) {
  out = ""
  while (length(s) > 0) {
    j = index(s, "$")
    if (j == 0) { out = out s; break }
    out = out substr(s, 1, j - 1)
    s = substr(s, j + 1)
    if (substr(s, 1, 1) == "{") {
      s = substr(s, 2)
      if (!match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
        warn("bad substitution \"${" s "\" at line " lineno "; BuildKit fails the file on it, so no base pulls from this expansion")
        UNCERTAIN = 1
        return out
      }
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      c = substr(s, 1, 1)
      if (c == "}") {
        s = substr(s, 2)
        out = out lookup(name, mode, lineno)
      } else if (c == ":") {
        mod = substr(s, 2, 1)
        if (mod != "-" && mod != "+") {
          warn("unsupported modifier in \"${" name ":" mod "...}\" at line " lineno ": only ${NAME}, ${NAME:-default} and ${NAME:+alt} can be verified textually")
          UNCERTAIN = 1
          return out
        }
        k = index(s, "}")
        if (k == 0) {
          warn("missing } in \"${" name s "\" at line " lineno)
          UNCERTAIN = 1
          return out
        }
        word = substr(s, 3, k - 3)
        s = substr(s, k + 1)
        if (word ~ /[${}"]/ || index(word, SQ) > 0 || index(word, ESC) > 0) {
          warn("nested expansion in \"${" name ":" mod word "}\" at line " lineno " cannot be verified textually")
          UNCERTAIN = 1
          return out
        }
        autocheck(name, lineno)
        if (unknown_var(name)) UNCERTAIN = 1
        if (UNCERTAIN) return out
        isset = (name in ARGS && ARGS[name] != "")
        if (mod == "-") out = out (isset ? ARGS[name] : word)
        else            out = out (isset ? word : "")
      } else if (c == "") {
        warn("missing } in \"${" name "\" at line " lineno)
        UNCERTAIN = 1
        return out
      } else {
        warn("unsupported variable modifier in \"${" name c "...}\" at line " lineno ": only ${NAME}, ${NAME:-default} and ${NAME:+alt} can be verified textually")
        UNCERTAIN = 1
        return out
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
# with neither tag nor digest gains :latest; a digest part is validated
# against the docker digest grammar (letter-led algorithm segments, then a
# colon and at least 32 hex digits) and kept verbatim. The whole
# distribution reference grammar is applied, so every hard classification
# and every allowed OK passes through it: the normalized path is at most
# 255 characters, the domain excluded (a bare 247-character name pulls in
# a real build and 248 fails with repository name must not be more than
# 255 characters, both pinned); a recognized domain is dot-separated
# components, each alphanumeric with interior hyphens, then an optional
# colon and a numeric port, or an IPv6 literal in square brackets (one or
# more hex digits and colons) with the optional port after the closing
# bracket (real builds accept [::1]:5000/alpine and [::1]/alpine and fail
# the pull on the connection, not the reference, while [::1:5000/alpine
# fails with invalid reference format, all pinned). A bracket form with no
# colon or dot in it ([dead]/alpine) is not recognized as a domain at all;
# it falls to the docker.io path, whose grammar refuses the brackets, and a
# real build refuses it the same way (pinned); each path component is
# lowercase alphanumerics joined by a single
# dot, a single underscore, a double underscore, or one or more hyphens; a
# tag starts with a letter, digit, or underscore and runs at most 128
# characters of word, dot, or hyphen characters. Returns the empty string
# for a value docker refuses (alpine:--, alpine@sha256:zzz, alpine..x,
# example.com:abc/alpine, [::1:5000/alpine, and an uppercase path component
# are each refused
# with invalid reference format, verified against real builds). BuildKit
# fails any build whose FROM needs such a value and buildx refuses such a
# context name, so an empty result never silently matches.
function norm_ref(r,   host, rest, dig, tag, slash, last, colon, dpos, hn, port, np, ci, comps) {
  if (r == "") return ""
  if (r ~ /[ \t\r]/ || index(r, VT) > 0 || index(r, FF) > 0) return ""
  dig = ""
  dpos = index(r, "@")
  if (dpos > 0) {
    dig = substr(r, dpos)
    r = substr(r, 1, dpos - 1)
    if (r == "" || length(dig) < 2) return ""
    if (dig !~ /^@[A-Za-z][A-Za-z0-9]*([-_+.][A-Za-z][A-Za-z0-9]*)*:[0-9A-Fa-f]+$/) return ""
    if (length(dig) - index(dig, ":") < 32) return ""
  }
  slash = index(r, "/")
  if (slash == 0) { host = "docker.io"; rest = r }
  else {
    host = substr(r, 1, slash - 1)
    if (host ~ /[.:]/ || host == "localhost" || host != tolower(host)) {
      rest = substr(r, slash + 1)
      hn = host
      if (substr(hn, 1, 1) == "[") {
        if (hn !~ /^\[[0-9A-Fa-f:]+\](:[0-9]+)?$/) return ""
      } else {
        colon = index(hn, ":")
        if (colon > 0) {
          port = substr(hn, colon + 1)
          hn = substr(hn, 1, colon - 1)
          if (port !~ /^[0-9]+$/) return ""
        }
        if (hn !~ /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/) return ""
      }
    }
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
    if (tag == "" || tag !~ /^[A-Za-z0-9_]/ || tag ~ /[^A-Za-z0-9_.-]/ || length(tag) > 128) return ""
  }
  if (host == "docker.io" && index(rest, "/") == 0) rest = "library/" rest
  np = split(rest, comps, "/")
  for (ci = 1; ci <= np; ci++)
    if (comps[ci] !~ /^[a-z0-9]+((\.|__|_|-+)[a-z0-9]+)*$/) return ""
  if (length(rest) > 255) return ""
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
      warn_halt("line " lineno " combines a heredoc-capable instruction with a Unicode space character; this check cannot split its words the way BuildKit does, so it cannot tell whether a heredoc opens")
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
      if (j == 0) {
        warn("unbalanced single quote on a heredoc-capable instruction at line " lineno ": this check cannot tell where its words end. BuildKit scans no heredocs on such a line (verified), so the scan continues with none open here")
        return -1
      }
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
      if (!q) {
        warn("unbalanced double quote on a heredoc-capable instruction at line " lineno ": this check cannot tell where its words end. BuildKit scans no heredocs on such a line (verified), so the scan continues with none open here")
        return -1
      }
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
    warn_halt("missing } in a ${ expansion on a heredoc-capable instruction at line " lineno "; this check cannot tell whether a heredoc opens on the line")
  inner = substr(s, i + 2, k - 1)
  ok = 0
  if (inner ~ /^[A-Za-z_][A-Za-z0-9_]*$/) ok = 1
  else if (inner ~ /^[A-Za-z_][A-Za-z0-9_]*:[-+][^ \t\r"\\<$]*$/ &&
           index(inner, SQ) == 0 && index(inner, VT) == 0 && index(inner, FF) == 0)
    ok = 1
  if (!ok)
    warn_halt("the expansion \"${" inner "}\" at line " lineno " is not supported on a heredoc-capable instruction: only ${NAME}, ${NAME:-word} and ${NAME:+word} with a plain word can be split into words the way BuildKit does, so this check cannot tell whether a heredoc opens on the line")
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
      warn_halt("heredoc marker \"" t "\" at line " lineno " is not supported by this check: the delimiter could not be classified with certainty, so the following lines cannot be told apart from instructions")
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
  WARNED = 0; HALT = 0; ARG_TAINT = 0; UNCERTAIN = 0
  STAGE_N = 0; NPEND = 0
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
  # cannot parse is a usage error (exit 2), because buildx refuses the
  # invocation (verified; it names the context and the lowercase repository
  # rule), so the captured build cannot run with it.
  N_CTX = 0
  n_bc = split(ENVIRON["CHECK_FROM_BUILD_CONTEXTS"], bc_lines, "\n")
  for (b = 1; b <= n_bc; b++) {
    if (bc_lines[b] == "") continue
    p = index(bc_lines[b], "=")
    if (p <= 1) continue
    cname = substr(bc_lines[b], 1, p - 1)
    cnorm = norm_ref(cname)
    if (cnorm == "") {
      print "check-from-lines: the build context name \"" cname "\" is not a valid image reference, so buildx refuses this invocation; the captured build cannot run with it"
      EXITCODE = 2
      exit 2
    }
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
        if (dkey in SEEN_DIRECTIVE) {
          warn("only one " dkey " parser directive can be used (line " NR "); BuildKit rejects the file, so the first value is kept and no base pulls as written")
          next
        }
        SEEN_DIRECTIVE[dkey] = 1
        if (dkey == "escape") {
          if (dval != "\\" && dval != "`") {
            warn("invalid escape directive value " SQ dval SQ " at line " NR ": must be \\ or `. BuildKit rejects the file, so no base pulls as written; the scan keeps the previous escape character")
            next
          }
          ESC = dval
        } else if (dkey == "syntax") {
          # Only the rolling tag, byte for byte, is verified. A pinned tag
          # parses by the pin, not by the rules this check implements
          # (BuildKit under docker/dockerfile:1.0 treats a heredoc body as
          # ordinary instructions, so a FROM inside it is a real FROM), and
          # BuildKit itself rejects an uppercase spelling such as
          # Docker/Dockerfile:1 as an invalid reference. The scan continues
          # under the rolling rules as a best effort; the oracle runs the
          # pinned frontend itself.
          if (dval != "docker/dockerfile:1" && dval != "docker.io/docker/dockerfile:1")
            warn("syntax directive " SQ dval SQ " at line " NR " pins a frontend; this textual check assumes the rolling docker/dockerfile:1 syntax and reads the rest of the file by its rules, and check-from-oracle.sh runs the pinned frontend and decides")
        }
        next
      }
      warn("the line at " NR " is shaped like a parser directive with the key " SQ dkey SQ ", which this check does not know; the rolling frontend reads it as a comment that ends the directive block, and the scan does the same")
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
  if (!HALT) {
    if (buf != "") process(ltrim(buf), bufline)
    if (EXITCODE) exit EXITCODE
    if (HD_N > 0 && HD_I <= HD_N)
      warn("unterminated heredoc (delimiter \"" HD_NAME[HD_I] "\" never appeared); BuildKit rejects the file, so no base pulls from it as written")
  }
  # Deferred bare-name FROMs, decided now that every stage name is known: a
  # name some other stage declares is a forward stage reference, which
  # BuildKit resolves as a stage and this sequential scan cannot verify; a
  # name no stage declares that BuildKit accepts as a reference is a pull
  # off the allowlist; a name BuildKit refuses pulls nothing. A stage is
  # never its own base (verified with a real run), so FROM alpine AS alpine
  # stays a pull. When the scan stopped early the stage list is incomplete
  # and every deferred name is reported instead of decided.
  for (pd = 1; pd <= NPEND; pd++) {
    fwd = 0
    for (js = 1; js <= STAGE_N; js++)
      if (js != PEND_STAGE[pd] && STAGE_ALIAS[js] == PEND_REF[pd]) { fwd = 1; break }
    if (HALT)
      warn("FROM \"" PEND_DISP[pd] "\" at line " PEND_LINE[pd] " could not be classified: the scan stopped before the stage list was complete")
    else if (fwd)
      warn("FROM \"" PEND_DISP[pd] "\" at line " PEND_LINE[pd] " references the stage \"" PEND_REF[pd] "\" declared later in the file; BuildKit resolves stage names anywhere in the file, so this is a stage reference and not a pull, but a sequential scan cannot verify a forward reference. check-from-oracle.sh decides it from the stage graph BuildKit itself reports")
    else if (norm_ref(PEND_DISP[pd]) != "")
      hard("FROM \"" PEND_DISP[pd] "\" at line " PEND_LINE[pd] " is not allowed: base images must come from cgr.dev/* or the configured external mirror")
    else
      warn("FROM \"" PEND_DISP[pd] "\" at line " PEND_LINE[pd] " is not a reference BuildKit accepts, so no base pulls from it as written; check-from-oracle.sh decides what the build does with this file")
  }
  if (WARNED) {
    printf "check-from-lines: %d UNVERIFIED construct(s) and no known off-allowlist base; check-from-oracle.sh decides what the build resolves\n", WARNED
    exit 3
  }
  exit 0
}

function process(logical, lineno,   n, f, instr, sub2, p, q, ref, resolved, alias, lc, i, ai, t, name, val, inner, litq, cnorm, anorm, csrc, checked, lc2, LEXW, ln) {
  n = split(logical, f, WS)
  if (n == 0) return
  instr = toupper(f[1])

  # Heredoc scanning lexes the whole logical line, as BuildKit does, so a
  # marker is recognized only where its << starts an unquoted word. A
  # negative word count is the unbalanced-quote report from lex_words:
  # BuildKit scans no heredocs on such a line, so neither does this check.
  if (instr == "RUN" || instr == "COPY" || instr == "ADD") {
    if (index(logical, "<<") > 0) {
      ln = lex_words(logical, lineno, LEXW)
      if (ln >= 0) scan_heredocs(LEXW, ln, lineno)
    }
    return
  }
  if (instr == "ONBUILD" && n >= 2) {
    sub2 = toupper(f[2])
    if ((sub2 == "RUN" || sub2 == "COPY" || sub2 == "ADD") && index(logical, "<<") > 0) {
      ln = lex_words(logical, lineno, LEXW)
      if (ln >= 0) scan_heredocs(LEXW, ln, lineno)
    }
    return
  }

  if (instr == "ARG" && !seen_from) {
    # Every assignment token on the line counts, matching docker build. A
    # --build-arg override beats the declared default, and gives a value to
    # an ARG declared with none. An override with no matching ARG
    # declaration never applies, also matching docker build. A declared
    # default for an automatic argument name replaces the automatic value
    # through this same flow, and an override beats it, exactly as BuildKit
    # applies them (verified with real builds). A token this check cannot
    # take apart leaves the whole ARG table unverified from that token on:
    # BuildKit reassembles such a line by rules this check does not model
    # (verified with real builds: ARG A="x y" B=alpine assigns B, while
    # ARG OTHER=a\ B=alpine swallows B= into the value of OTHER), so any name
    # could have been assigned, and every later variable read is uncertain
    # until the name is assigned again.
    for (ai = 2; ai <= n; ai++) {
      t = f[ai]
      if (index(t, ESC) > 0) {
        warn("ARG at line " lineno " contains the escape character in \"" t "\"; BuildKit joins escaped whitespace by rules this check does not model, so what this line assigns cannot be verified and later variable reads are unverified too")
        taint_args()
        return
      }
      p = index(t, "=")
      if (p == 0) {
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (t in OVERRIDE)) { ARGS[t] = OVERRIDE[t]; CLEAN[t] = 1; delete ARGS_UNKNOWN[t] }
        continue
      }
      if (p == 1) {
        warn("ARG at line " lineno " declares an assignment with an empty name (\"" t "\"); this check cannot tell what the line assigns, so later variable reads are unverified too (BuildKit rejects the file)")
        taint_args()
        return
      }
      name = substr(t, 1, p - 1)
      val = substr(t, p + 1)
      litq = 0
      if (index(val, "\"") > 0 || index(val, SQ) > 0) {
        q = substr(val, 1, 1)
        inner = substr(val, 2, length(val) - 2)
        if ((q != "\"" && q != SQ) || length(val) < 2 || substr(val, length(val), 1) != q || index(inner, q) > 0) {
          warn("ARG at line " lineno " has a quoted value this check cannot take apart (\"" t "\"): a quoted value spanning whitespace or a stray quote is reassembled by rules this check does not model, so what this line assigns cannot be verified and later variable reads are unverified too")
          taint_args()
          return
        }
        val = inner
        # BuildKit keeps a single-quoted default literal (verified with an
        # outline run; the value ${UNSET} survives as those seven
        # characters), where a double-quoted or unquoted default expands.
        if (q == SQ) litq = 1
      }
      if (name in OVERRIDE) { ARGS[name] = OVERRIDE[name]; CLEAN[name] = 1; delete ARGS_UNKNOWN[name] }
      else if (litq) { ARGS[name] = val; CLEAN[name] = 1; delete ARGS_UNKNOWN[name] }
      else {
        UNCERTAIN = 0
        val = expand_str(val, "default", lineno)
        if (UNCERTAIN) { delete ARGS[name]; ARGS_UNKNOWN[name] = 1 }
        else { ARGS[name] = val; delete ARGS_UNKNOWN[name] }
        CLEAN[name] = 1
      }
    }
    return
  }

  if (instr != "FROM") return
  seen_from = 1
  STAGE_N++

  # Skip flags (--platform=... etc.) to reach the image ref.
  i = 2
  while (i <= n && substr(f[i], 1, 2) == "--") i++
  if (i > n) {
    warn("FROM at line " lineno " has no image reference; BuildKit fails such a line with \"FROM requires either one or three arguments\", so no base pulls from it as written")
    return
  }
  # After the flags, exactly one image reference, optionally followed by AS
  # and a stage name. BuildKit fails every other token count, including
  # three tokens whose middle one is not AS, with "FROM requires either one
  # or three arguments", so no base pulls from such a line as written and
  # extra tokens can never hide a reference from this check.
  if (n - i != 0 && !(n - i == 2 && toupper(f[i + 1]) == "AS")) {
    warn("FROM at line " lineno " (\"" logical "\") does not have exactly one image reference plus an optional AS name; BuildKit fails such a line with \"FROM requires either one or three arguments\", so no base pulls from it as written")
    return
  }
  ref = f[i]

  # The alias parses first: the advisory paths below register it, because
  # the stage is a real name for later FROMs whatever its base turns out to
  # be. An alias outside the Docker stage-name shape is REJECTED, not
  # reported: the alias table decides what every later FROM in this file
  # means, so a name this check cannot trust would poison every decision
  # after it.
  alias = ""
  if (i + 2 <= n && toupper(f[i + 1]) == "AS") {
    alias = f[i + 2]
    if (alias !~ /^[a-zA-Z][a-zA-Z0-9_.-]*$/)
      hard("FROM stage alias \"" alias "\" at line " lineno " is not allowed: aliases must match ^[a-zA-Z][a-zA-Z0-9_.-]*$ (Docker stage-name rules)")
    alias = tolower(alias)
    STAGE_ALIAS[STAGE_N] = alias
  }

  # A context whose name matches the AS name of this stage applies at the
  # stage definition, replacing the base of the stage even when no FROM
  # references the name, with reference normalization on the name (a docker.io/library/
  # spelling matches a bare stage name) and case-insensitively on the
  # alias, and it beats a context matching the base reference and a
  # scratch base alike; each rule pinned by an outline run (the scratch
  # replacement by a real cacheonly build too). The base as written is
  # never pulled, so the context source stands in for it entirely, before
  # any expansion of the written base.
  if (alias != "" && N_CTX > 0) {
    anorm = norm_ref(alias)
    if (anorm != "" && (anorm in CTX)) {
      csrc = CTX[anorm]
      if (substr(csrc, 1, 15) != "docker-image://") {
        warn("the stage \"" alias "\" at line " lineno " is overridden by a --build-context whose source (" csrc ") is not a docker-image:// reference. BuildKit builds the stage from that source in place of its base, and a base taken from a local directory, a git repository, an oci layout, or another build target has no registry reference this check can verify")
        ALIASES[alias] = 1
        return
      }
      checked = substr(csrc, 16)
      # The substituted reference must be one docker accepts before it can
      # be allowed or rejected: buildx accepts the flag and the build then
      # fails on an empty or invalid docker-image:// reference (invalid
      # reference format, verified), so no base pulls from it as written.
      if (norm_ref(checked) == "") {
        warn("the stage \"" alias "\" at line " lineno " is overridden by a --build-context whose docker-image:// reference \"" checked "\" is not a valid image reference; BuildKit fails the build on it (invalid reference format), so no base pulls from it as written, and check-from-oracle.sh decides what the build does with this invocation")
        ALIASES[alias] = 1
        return
      }
      lc2 = tolower(checked)
      ok = 0
      if (substr(lc2, 1, 8) == "cgr.dev/") ok = 1
      else if (mirror != "" && substr(lc2, 1, length(mirror) + 1) == mirror "/") ok = 1
      if (!ok)
        hard("the stage \"" alias "\" at line " lineno " (base \"" ref "\") is overridden by --build-context to \"" checked "\", which is not allowed: base images must come from cgr.dev/* or the configured external mirror")
      ALIASES[alias] = 1
      return
    }
  }

  UNRESOLVED = ""
  UNCERTAIN = 0
  resolved = expand_str(ref, "from", lineno)
  if (UNCERTAIN) {
    warn("FROM \"" ref "\" at line " lineno " could not be resolved textually; an UNVERIFIED construct above decides its value, and check-from-oracle.sh resolves it")
    if (alias != "") ALIASES[alias] = 1
    return
  }
  # An undeclared or unset variable expands to the empty string, as
  # BuildKit expands it, and the reference that remains is classified
  # below like any other (a real build of FROM alpine${UNSET} resolves
  # docker.io/library/alpine). Only a reference that expands wholly empty
  # is reported: BuildKit refuses an empty base (base name should not be
  # blank, verified with a real build), so no base pulls from it as
  # written.
  if (resolved == "") {
    if (UNRESOLVED != "")
      warn("FROM \"" ref "\" at line " lineno " expands to an empty base: the variable(s)" UNRESOLVED " have no value on the captured invocation and expand to the empty string, as BuildKit expands them, and BuildKit refuses an empty base (base name should not be blank), so no base pulls from it as written. check-from-oracle.sh decides what the build does with this file")
    else
      warn("FROM \"" ref "\" at line " lineno " expands to an empty base, which BuildKit refuses (base name should not be blank), so no base pulls from it as written. check-from-oracle.sh decides what the build does with this file")
    if (alias != "") ALIASES[alias] = 1
    return
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
        if (substr(csrc, 1, 15) != "docker-image://") {
          warn("FROM \"" resolved "\" at line " lineno " is overridden by a --build-context whose source (" csrc ") is not a docker-image:// reference. A base taken from a local directory, a git repository, an oci layout, or another build target has no registry reference this check can verify")
          if (alias != "") ALIASES[alias] = 1
          return
        }
        checked = substr(csrc, 16)
        # Same validity check as the stage-name site above: an empty or
        # invalid docker-image:// reference pulls nothing (the build fails
        # on it with invalid reference format, verified), so it is reported,
        # never allowed and never rejected.
        if (norm_ref(checked) == "") {
          warn("FROM \"" resolved "\" at line " lineno " is overridden by a --build-context whose docker-image:// reference \"" checked "\" is not a valid image reference; BuildKit fails the build on it (invalid reference format), so no base pulls from it as written, and check-from-oracle.sh decides what the build does with this invocation")
          if (alias != "") ALIASES[alias] = 1
          return
        }
        lc2 = tolower(checked)
        if (substr(lc2, 1, 8) == "cgr.dev/") ok = 1
        else if (mirror != "" && substr(lc2, 1, length(mirror) + 1) == mirror "/") ok = 1
        if (!ok)
          hard("FROM \"" resolved "\" at line " lineno " is overridden by --build-context to \"" checked "\", which is not allowed: base images must come from cgr.dev/* or the configured external mirror")
      }
    }
    if (!ok) {
      if (lc in ALIASES) ok = 1
      else if (substr(lc, 1, 8) == "cgr.dev/" ||
               (mirror != "" && substr(lc, 1, length(mirror) + 1) == mirror "/")) {
        # An allowed prefix is not enough on its own: a reference BuildKit
        # refuses (cgr.dev/chainguard/:latest-dev, left by an empty
        # expansion, fails a real build with invalid reference format)
        # pulls nothing, so the check reports it instead of vouching for a
        # base that never enters the build.
        if (norm_ref(resolved) != "") ok = 1
        else {
          warn("FROM \"" resolved "\" at line " lineno " matches the allowlist prefix but is not a reference BuildKit accepts, so no base pulls from it as written; check-from-oracle.sh decides what the build does with this file")
          if (alias != "") ALIASES[alias] = 1
          return
        }
      }
    }
  }

  if (!ok) {
    # A bare name in stage-name shape could be a forward reference to a
    # stage declared later, which BuildKit resolves as a stage, not a pull
    # (verified with an outline run), so its classification is deferred to
    # the end of the scan, when every stage name is known. Anything else
    # is decided here: a reference BuildKit accepts is a base the build
    # pulls off the allowlist, and a reference BuildKit refuses pulls
    # nothing.
    if (resolved ~ /^[a-zA-Z][a-zA-Z0-9_.-]*$/) {
      NPEND++
      PEND_REF[NPEND] = lc
      PEND_DISP[NPEND] = resolved
      PEND_LINE[NPEND] = lineno
      PEND_STAGE[NPEND] = STAGE_N
    } else if (norm_ref(resolved) != "") {
      hard("FROM \"" resolved "\" at line " lineno " is not allowed: base images must come from cgr.dev/* or the configured external mirror")
    } else {
      warn("FROM \"" resolved "\" at line " lineno " is not a reference BuildKit accepts, so no base pulls from it as written; check-from-oracle.sh decides what the build does with this file")
    }
  }

  if (alias != "") ALIASES[alias] = 1
}
' < "$DOCKERFILE"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "check-from-lines: OK — every FROM in $DOCKERFILE is on the allowlist"
fi
exit "$rc"
