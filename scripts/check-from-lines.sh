#!/bin/sh
# check-from-lines.sh — gate every FROM in a Dockerfile against the migration
# allowlist: cgr.dev/* (exact host boundary), the configured external mirror
# prefix (on a / boundary), scratch, and previously declared stage aliases.
#
# Usage: check-from-lines.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]]
#                            [--build-platform OS/ARCH[/VARIANT]] [--target NAME]
#                            [--build-arg NAME=value ...] DOCKERFILE
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
#
# Exit codes: 0 = all FROMs allowed; 1 = a FROM (or stage alias, or ARG
# expansion, or a construct this gate refuses to guess about) is not allowed,
# with a message naming the line; 2 = usage error.
#
# Semantics ported from Guardener's static validator and checked against
# BuildKit (the parser rules below were each verified against
# docker buildx build --call=outline on the builtin Dockerfile frontend):
#   - Parser directives: consecutive '# key=value' lines from the top of the
#     file (leading whitespace and a UTF-8 BOM allowed, keys case-insensitive).
#     The block ends at the first line that is not a known directive (a
#     plain comment, a blank line, an unknown key, or an instruction). '# escape=' is
#     honored for backslash and backtick; any other value is rejected with
#     exit 1, as BuildKit itself errors on it. A duplicate directive is
#     rejected the same way. '# syntax=' is accepted only for the stable
#     docker/dockerfile:1 frontend; any other frontend may parse the file by
#     different rules than this gate implements, so it is rejected.
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
#     may be wrapped in one pair of quotes; a quoted value spanning
#     whitespace, a stray quote, or an escape character in any token is
#     rejected with exit 1 rather than reassembled. ARGs declared after a
#     FROM are ignored for FROM resolution. A --build-arg override replaces
#     the default of a matching ARG declared before the first FROM, and gives
#     a value to a global ARG declared with no default. An override whose
#     name no ARG declares is ignored, as in docker build.
#   - Variable expansion supports $NAME, ${NAME}, ${NAME:-default} (default
#     when unset or empty) and ${NAME:+alt} (alt when set and non-empty),
#     with BuildKit's semantics. Every other modifier (%, #, /, ^, and the
#     colon-less - and + forms) is rejected with exit 1 naming the
#     expression, never expanded to an empty string.
#   - FROM flags such as --platform=... are skipped to reach the image ref.
#   - Automatic platform arguments: BuildKit seeds TARGETPLATFORM, TARGETOS,
#     TARGETARCH, TARGETVARIANT, TARGETOSVERSION, TARGETSTAGE, BUILDPLATFORM,
#     BUILDOS, BUILDARCH, BUILDVARIANT, and BUILDOSVERSION in the global
#     scope on every build, so a FROM (or a global ARG default) can read
#     them with no declaration. When the gate runs with --platform it seeds
#     the same values, normalized the way the docker CLI normalizes a
#     platform string (x86_64 and aarch64 become amd64 and arm64, arm64/v8
#     drops its variant, bare arm becomes arm/v7; each verified against a
#     real build). TARGETVARIANT and the OSVERSION arguments are set to the
#     empty string when the platform has none, which matters for the :- and
#     :+ modifiers. A bare global redeclaration (ARG TARGETARCH) keeps the
#     seeded value, a global declaration with a default replaces it, and a
#     --build-arg override beats both, with or without a declaration, all
#     matching BuildKit. When --platform was not given and FROM resolution
#     reads one of these names, the gate exits 1 naming it and asking for
#     --platform (or --target, for TARGETSTAGE), because BuildKit resolves
#     a value the gate does not know. A file that never reads them behaves
#     as before.
#   - Unresolved variables in a FROM ref are rejected: FROM $UNSET could
#     resolve to anything at build time, so it cannot pass a static gate.
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
# rejected rather than emulated; a single-quoted ARG
# default is expanded like a double-quoted one, where BuildKit keeps it
# literal (a literal $ never survives into a valid image ref, so this cannot
# admit a ref the builder resolves elsewhere); and with --platform but no
# --build-platform the BUILD* arguments take the target platform's values,
# which matches every same-platform build but differs on a cross-platform
# one until the caller passes --build-platform.
#
# Dependencies: sh, awk (POSIX). No network, no writes.

set -u

NL='
'

MIRROR=""
BUILD_ARGS=""
PLATFORM=""
BUILD_PLATFORM=""
TARGET_STAGE=""
TARGET_SET=0

# normalize_platform VALUE FLAG: split VALUE into NORM_OS, NORM_ARCH,
# NORM_VARIANT and apply the normalizations the docker CLI applies before
# the builder sees the platform, each verified against a real build:
# x86_64 and x86-64 become amd64, aarch64 becomes arm64, i386 becomes 386,
# armhf and armel become arm/v7 and arm/v6, arm64 drops a v8 variant, and
# bare arm gains v7.
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
  case "$NORM_ARCH" in
    x86_64|x86-64) NORM_ARCH=amd64 ;;
    aarch64) NORM_ARCH=arm64 ;;
    i386) NORM_ARCH=386 ;;
    armhf|armel)
      if [ -n "$NORM_VARIANT" ]; then
        echo "check-from-lines.sh: $2 does not take a variant with '$NORM_ARCH'; spell the platform as $NORM_OS/arm/vN" >&2
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
    *) break ;;
  esac
done

DOCKERFILE="${1-}"
if [ -z "$DOCKERFILE" ] || [ ! -f "$DOCKERFILE" ]; then
  echo "usage: check-from-lines.sh [--mirror PREFIX] [--platform OS/ARCH[/VARIANT]] [--build-platform OS/ARCH[/VARIANT]] [--target NAME] [--build-arg NAME=value ...] DOCKERFILE" >&2
  exit 2
fi

if [ -n "$BUILD_PLATFORM" ] && [ -z "$PLATFORM" ]; then
  echo "check-from-lines.sh: --build-platform needs --platform as well" >&2
  exit 2
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

# Build args travel through the environment, not -v: awk -v runs backslash
# escape processing on the value, which would corrupt a value containing one.
# The Dockerfile is fed on stdin, not as an operand: a bare operand shaped
# like name=value is treated by POSIX awk as a variable assignment, so a file
# literally named "from=allowed" would never be read and the gate would pass.
# LC_ALL=C keeps awk bytewise: in a UTF-8 locale, gawk builds sprintf("%c")
# strings and indexes substrings by character, which would break the BOM
# comparison and the Unicode-space detection.
# The platform values reach awk through -v, which is safe here: they are
# validated above to letters, digits, and [_./-], none of which awk escape
# processing touches.
CHECK_FROM_BUILD_ARGS="$BUILD_ARGS" LC_ALL=C awk -v mirror="$MIRROR" \
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
  mirror = tolower(mirror)
  sub(/\/+$/, "", mirror)
  sub(/^[ \t]+/, "", mirror); sub(/[ \t]+$/, "", mirror)
  n_ba = split(ENVIRON["CHECK_FROM_BUILD_ARGS"], ba_lines, "\n")
  for (b = 1; b <= n_ba; b++) {
    if (ba_lines[b] == "") continue
    p = index(ba_lines[b], "=")
    if (p > 1) OVERRIDE[substr(ba_lines[b], 1, p - 1)] = substr(ba_lines[b], p + 1)
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
          if (tolower(dval) !~ /^(docker\.io\/)?docker\/dockerfile:1(\.[0-9]+)*$/)
            fail("syntax directive " SQ dval SQ " at line " NR " selects a frontend whose parsing rules this gate cannot verify; only the stable docker/dockerfile:1 syntax is supported")
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

function process(logical, lineno,   n, f, instr, sub2, p, q, ref, resolved, alias, lc, i, ai, t, name, val, inner, LEXW, ln) {
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
      if (index(val, "\"") > 0 || index(val, SQ) > 0) {
        q = substr(val, 1, 1)
        inner = substr(val, 2, length(val) - 2)
        if ((q != "\"" && q != SQ) || length(val) < 2 || substr(val, length(val), 1) != q || index(inner, q) > 0)
          fail("ARG at line " lineno " has a quoted value this gate cannot take apart (\"" t "\"): a quoted value spanning whitespace or a stray quote is not supported. Quote the whole value or none of it")
        val = inner
      }
      if (name in OVERRIDE) ARGS[name] = OVERRIDE[name]
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

  lc = tolower(resolved)
  ok = 0
  if (lc == "scratch") ok = 1
  else if (lc in ALIASES) ok = 1
  else if (substr(lc, 1, 8) == "cgr.dev/") ok = 1
  else if (mirror != "" && substr(lc, 1, length(mirror) + 1) == mirror "/") ok = 1

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
