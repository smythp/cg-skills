#!/bin/sh
# apk-lookup.sh — answer "does package X exist" and "what provides binary or
# library Y" against the same apk index a migrated build will use, by running
# apk inside a Chainguard container. Never executes anything from the images
# being migrated.
#
# Usage:
#   apk-lookup.sh [--org ORG] exact NAME [NAME...]    exact package names; exit 1 if any is missing
#   apk-lookup.sh [--org ORG] search TERM [TERM...]   substring name search
#   apk-lookup.sh [--org ORG] cmd BINARY [BINARY...]  which package provides a command
#   apk-lookup.sh [--org ORG] so LIBNAME [LIBNAME...] which package provides a shared library (e.g. libssl.so.3)
#
# --org ORG adds the organization's index at https://apk.cgr.dev/ORG,
# authenticated with a short-lived token minted via
# `chainctl auth token --audience apk.cgr.dev`. The token travels only as an
# inherited environment variable into the container (docker reads -e HTTP_AUTH
# from this process's environment, so the value never appears on a command
# line) and is never printed.
#
# Exit codes: 0 = every query matched; 1 = at least one query had no match or
# the lookup failed; 2 = usage error.
#
# Dependencies: sh, docker (daemon running); chainctl only when --org is used.
# LOOKUP_IMAGE overrides the container (default cgr.dev/chainguard/wolfi-base:latest).

set -u

LOOKUP_IMAGE="${LOOKUP_IMAGE:-cgr.dev/chainguard/wolfi-base:latest}"
ORG=""

if [ "${1-}" = "--org" ]; then
  ORG="${2-}"
  [ -n "$ORG" ] || { echo "apk-lookup: --org needs a value" >&2; exit 2; }
  shift 2
fi

MODE="${1-}"
case "$MODE" in
  exact|search|cmd|so) shift ;;
  *) echo "usage: apk-lookup.sh [--org ORG] exact|search|cmd|so QUERY [QUERY...]" >&2; exit 2 ;;
esac
[ "$#" -ge 1 ] || { echo "apk-lookup: at least one query required" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || { echo "apk-lookup: docker not found" >&2; exit 1; }

# Queries are interpolated into a shell command inside the container, so
# restrict them to package/file-name characters. Rejecting here beats quoting
# games: a query outside this set is a typo or an injection attempt.
for q in "$@"; do
  case "$q" in
    *[!A-Za-z0-9._+:@=-]*)
      echo "apk-lookup: query '$q' contains characters outside [A-Za-z0-9._+:@=-]" >&2
      exit 2
      ;;
  esac
done

# Validate the org slug for the same reason (it lands in a repositories line).
if [ -n "$ORG" ]; then
  case "$ORG" in
    *[!A-Za-z0-9._-]*)
      echo "apk-lookup: org '$ORG' contains characters outside [A-Za-z0-9._-]" >&2
      exit 2
      ;;
  esac
fi

inner="set -e; "
if [ -n "$ORG" ]; then
  command -v chainctl >/dev/null 2>&1 || { echo "apk-lookup: --org needs chainctl for the token" >&2; exit 1; }
  token="$(chainctl auth token --audience apk.cgr.dev)" || { echo "apk-lookup: could not mint apk.cgr.dev token (chainctl auth token failed)" >&2; exit 1; }
  HTTP_AUTH="basic:apk.cgr.dev:user:$token"
  export HTTP_AUTH
  unset token
  inner="${inner}echo https://apk.cgr.dev/$ORG >> /etc/apk/repositories; "
fi
inner="${inner}apk -q update >/dev/null 2>&1 || { echo 'apk-lookup: apk update failed (network or auth)'; exit 3; }; missing=0; "

for q in "$@"; do
  case "$MODE" in
    exact)  apkq="-e $q" ;;
    search) apkq="$q" ;;
    cmd)    apkq="-e cmd:$q" ;;
    so)     apkq="-e so:$q" ;;
  esac
  inner="${inner}r=\$(apk search -q $apkq); if [ -n \"\$r\" ]; then echo \"$q: \$(echo \$r | tr '\n' ' ')\"; else echo \"$q: NOT FOUND\"; missing=1; fi; "
done
inner="${inner}exit \$missing"

if [ -n "$ORG" ]; then
  docker run --rm -e HTTP_AUTH "$LOOKUP_IMAGE" sh -c "$inner"
else
  docker run --rm "$LOOKUP_IMAGE" sh -c "$inner"
fi
rc=$?
if [ "$rc" -eq 3 ]; then
  echo "apk-lookup: index update failed; results unavailable (not the same as NOT FOUND)" >&2
  exit 1
fi
exit "$rc"
