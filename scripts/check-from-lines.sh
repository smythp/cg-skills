#!/bin/sh
# check-from-lines.sh — gate every FROM in a Dockerfile against the migration
# allowlist: cgr.dev/* (exact host boundary), the configured external mirror
# prefix (on a / boundary), scratch, and previously declared stage aliases.
#
# Usage: check-from-lines.sh [--mirror PREFIX] [--build-arg NAME=value ...] DOCKERFILE
#   --mirror PREFIX       external pull-through mirror, e.g. my-corp.example.io/cg
#   --build-arg NAME=value  a build arg from the captured build invocation;
#                         repeatable. docker build honors these over the
#                         Dockerfile's ARG defaults, so the gate must apply
#                         the same overrides or it checks a different file
#                         than the one being built.
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
#     (2<<NAME), and BuildKit's separated form << NAME (the lexer attaches
#     the following word as the delimiter; <<- NAME with a space is NOT a
#     heredoc, and a bare << at end of line is not either). The content lines
#     up to and including the line equal to each delimiter, in order, are
#     file content, not instructions and not comments; for <<- the delimiter
#     comparison strips leading tabs; otherwise the comparison is exact, so a
#     delimiter line with trailing whitespace does not terminate. A heredoc
#     marker this gate cannot classify with certainty (a quoted name spanning
#     whitespace, a name containing a quote, $, the escape character, or
#     other unusual characters) is rejected with exit 1 rather than guessed
#     at, and an unterminated heredoc is rejected as BuildKit rejects it.
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
# quoted or escaped whitespace in ARG values, ambiguous heredoc markers, and
# non-stable '# syntax=' frontends are all rejected rather than emulated; and
# a single-quoted ARG default is expanded like a double-quoted one, where
# BuildKit keeps it literal (a literal $ never survives into a valid image
# ref, so this cannot admit a ref the builder resolves elsewhere).
#
# Dependencies: sh, awk (POSIX). No network, no writes.

set -u

NL='
'

MIRROR=""
BUILD_ARGS=""
while :; do
  case "${1-}" in
    --mirror)
      MIRROR="${2-}"
      [ -n "$MIRROR" ] || { echo "check-from-lines.sh: --mirror needs a value" >&2; exit 2; }
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
  echo "usage: check-from-lines.sh [--mirror PREFIX] [--build-arg NAME=value ...] DOCKERFILE" >&2
  exit 2
fi

# Build args travel through the environment, not -v: awk -v runs backslash
# escape processing on the value, which would corrupt a value containing one.
# The Dockerfile is fed on stdin, not as an operand: a bare operand shaped
# like name=value is treated by POSIX awk as a variable assignment, so a file
# literally named "from=allowed" would never be read and the gate would pass.
CHECK_FROM_BUILD_ARGS="$BUILD_ARGS" awk -v mirror="$MIRROR" '
# rtrim_c trims only what BuildKit ignores before its continuation check
# (\r from CRLF, then spaces and tabs); ltrim matches BuildKit trimming
# any leading whitespace before the comment and blank-line checks.
function rtrim_c(s) { sub(/\r$/, "", s); sub(/[ \t]+$/, "", s); return s }
function ltrim(s)   { sub(WSL, "", s); return s }

function fail(msg) { print "check-from-lines: " msg; EXITCODE = 1; exit 1 }

# Resolve one variable name. In "from" mode an unknown name is collected in
# UNRESOLVED instead of guessed at; in "default" mode it expands to the empty
# string, matching the builder.
function lookup(name, mode) {
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
        out = out lookup(name, mode)
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
      out = out lookup(name, mode)
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

# Detect the heredocs a logical RUN/COPY/ADD (or ONBUILD thereof) line opens,
# in order, mirroring BuildKit: a token of optional digits then << starts one.
# An attached rest (<<EOF, <<-EOF, quoted forms) carries the name; a bare <<
# takes the NEXT token as its name (the lexer glues the whitespace and the
# following word into one heredoc word); a bare <<- followed by whitespace is
# not a heredoc, and neither is a rest containing another < character.
function scan_heredocs(f, n, lineno,   i, t, body, chomp, name) {
  for (i = 2; i <= n; i++) {
    t = f[i]
    if (t !~ /^[0-9]*<</) continue
    body = t
    sub(/^[0-9]*<</, "", body)
    if (body == "") {
      # bare << (or fd<<): the next token is the delimiter
      if (i == n) continue
      i++
      name = strict_heredoc_name(f[i])
      if (name == "")
        fail("heredoc marker \"" t " " f[i] "\" at line " lineno " is not supported by this gate: the delimiter could not be classified with certainty, so the following lines cannot be told apart from instructions. Use a plain <<NAME heredoc")
      HD_N++; HD_NAME[HD_N] = name; HD_CHOMP[HD_N] = 0
    } else if (body == "-") {
      # "<<- NAME" with a space is not a heredoc to BuildKit; the marker is
      # inert and the following lines stay instructions for both of us.
      continue
    } else {
      chomp = 0
      if (substr(body, 1, 1) == "-") { chomp = 1; body = substr(body, 2) }
      if (index(body, "<") > 0) continue   # not a heredoc to BuildKit either
      name = strict_heredoc_name(body)
      if (name == "")
        fail("heredoc marker \"" t "\" at line " lineno " is not supported by this gate: the delimiter could not be classified with certainty, so the following lines cannot be told apart from instructions. Use a plain <<NAME heredoc")
      HD_N++; HD_NAME[HD_N] = name; HD_CHOMP[HD_N] = chomp
    }
  }
}

BEGIN {
  SQ = sprintf("%c", 39)   # single quote, kept out of the awk source for portability
  BOM = sprintf("%c%c%c", 239, 187, 191)
  # Word splitting and leading-whitespace trimming match BuildKit, which
  # treats vertical tab and form feed as separators too.
  WS  = sprintf("[ \t\r%c%c]+", 11, 12)
  WSL = "^" WS
  CTRL_WS = sprintf("[%c%c\r]", 11, 12)
  ESC = "\\"
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

function process(logical, lineno,   n, f, instr, sub2, p, q, ref, resolved, alias, lc, i, ai, t, name, val, inner) {
  n = split(logical, f, WS)
  if (n == 0) return
  instr = toupper(f[1])

  if (instr == "RUN" || instr == "COPY" || instr == "ADD") {
    if (index(logical, "<<") > 0) scan_heredocs(f, n, lineno)
    return
  }
  if (instr == "ONBUILD" && n >= 2) {
    sub2 = toupper(f[2])
    if ((sub2 == "RUN" || sub2 == "COPY" || sub2 == "ADD") && index(logical, "<<") > 0)
      scan_heredocs(f, n, lineno)
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
