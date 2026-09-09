#!/bin/sh
# check-from-lines.sh — gate every FROM in a Dockerfile against the migration
# allowlist: cgr.dev/* (exact host boundary), the configured external mirror
# prefix (on a / boundary), scratch, and previously declared stage aliases.
#
# Usage: check-from-lines.sh [--mirror PREFIX] DOCKERFILE
#   --mirror PREFIX   external pull-through mirror, e.g. my-corp.example.io/cg
#
# Exit codes: 0 = all FROMs allowed; 1 = a FROM (or stage alias, or ARG
# expansion) is not allowed, with a message naming the line; 2 = usage error.
#
# Semantics ported from Guardener's static validator:
#   - ARG defaults declared before the first FROM are expanded inside FROM
#     refs (quotes stripped, earlier ARGs usable in later defaults). ARGs
#     declared after a FROM are ignored for FROM resolution.
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
# never the reverse): variable modifiers like ${NAME:-default} are rejected
# as unresolved, and a non-backslash escape character declared with a
# '# escape=' directive is not honored.
#
# Dependencies: sh, awk (POSIX). No network, no writes.

set -u

MIRROR=""
case "${1-}" in
  --mirror)
    MIRROR="${2-}"
    [ -n "$MIRROR" ] || { echo "check-from-lines.sh: --mirror needs a value" >&2; exit 2; }
    shift 2
    ;;
esac

DOCKERFILE="${1-}"
if [ -z "$DOCKERFILE" ] || [ ! -f "$DOCKERFILE" ]; then
  echo "usage: check-from-lines.sh [--mirror PREFIX] DOCKERFILE" >&2
  exit 2
fi

awk -v mirror="$MIRROR" '
function rtrim(s) { sub(/[ \t\r]+$/, "", s); return s }
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }

# Expand $NAME / ${NAME} in an ARG default. Unknown names expand to the
# empty string (matching the builder), never to an error.
function expand_default(s,   out, j, k, name) {
  out = ""
  while (length(s) > 0) {
    j = index(s, "$")
    if (j == 0) { out = out s; break }
    out = out substr(s, 1, j - 1)
    s = substr(s, j + 1)
    if (substr(s, 1, 1) == "{") {
      k = index(s, "}")
      if (k == 0) { return out "$" s }
      name = substr(s, 2, k - 2)
      s = substr(s, k + 1)
      if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (name in ARGS))
        out = out ARGS[name]
    } else if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      if (name in ARGS) out = out ARGS[name]
    } else {
      out = out "$"
    }
  }
  return out
}

# Expand $NAME / ${NAME} in a FROM ref. Any name not defined as a global ARG
# default is unresolved; collect it in UNRESOLVED instead of guessing.
function expand_from(s,   out, j, k, name) {
  out = ""; UNRESOLVED = ""
  while (length(s) > 0) {
    j = index(s, "$")
    if (j == 0) { out = out s; break }
    out = out substr(s, 1, j - 1)
    s = substr(s, j + 1)
    if (substr(s, 1, 1) == "{") {
      k = index(s, "}")
      if (k == 0) { UNRESOLVED = UNRESOLVED " ${"; return out }
      name = substr(s, 2, k - 2)
      s = substr(s, k + 1)
      if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (name in ARGS))
        out = out ARGS[name]
      else
        UNRESOLVED = UNRESOLVED " " name
    } else if (match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(s, RSTART, RLENGTH)
      s = substr(s, RLENGTH + 1)
      if (name in ARGS) out = out ARGS[name]
      else UNRESOLVED = UNRESOLVED " " name
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

function fail(msg) { print "check-from-lines: " msg; EXITCODE = 1; exit 1 }

BEGIN {
  SQ = sprintf("%c", 39)   # single quote, kept out of the awk source for portability
  seen_from = 0
  buf = ""; bufline = 0
  mirror = tolower(mirror)
  sub(/\/+$/, "", mirror)
  sub(/^[ \t]+/, "", mirror); sub(/[ \t]+$/, "", mirror)
}

{
  line = rtrim($0)
  trimmed = ltrim(line)
  # Comment lines are dropped entirely, even inside a continuation,
  # matching the Dockerfile parser.
  if (trimmed ~ /^#/) next
  if (buf == "" && trimmed == "") next
  if (buf == "") bufline = NR
  if (line ~ /\\$/) { buf = buf " " substr(line, 1, length(line) - 1); next }
  buf = buf " " line
  logical = ltrim(buf); buf = ""
  process(logical, bufline)
}

END {
  if (EXITCODE) exit EXITCODE
  if (buf != "") process(ltrim(buf), bufline)
  exit EXITCODE + 0
}

function process(logical, lineno,   n, f, instr, p, ref, resolved, alias, lc, i, rest) {
  n = split(logical, f, /[ \t]+/)
  if (n == 0) return
  instr = toupper(f[1])

  if (instr == "ARG" && !seen_from) {
    # Only the first name=value token counts, and only when it has a default.
    if (n >= 2) {
      p = index(f[2], "=")
      if (p > 1) {
        name = substr(f[2], 1, p - 1)
        val = strip_quotes(substr(f[2], p + 1))
        ARGS[name] = expand_default(val)
      }
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

  resolved = expand_from(ref)
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
' "$DOCKERFILE"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "check-from-lines: OK — every FROM in $DOCKERFILE is on the allowlist"
fi
exit "$rc"
