#!/bin/sh
# apk-lookup.sh — answer "does package X exist" and "what provides binary or
# library Y" against the same apk index a migrated build will use, by running
# apk inside a Chainguard container. Never executes anything from the images
# being migrated.
#
# Usage:
#   apk-lookup.sh [--org ORG] QUERY [QUERY...]
#     QUERY is an exact package name (curl), cmd:BINARY (which package
#     provides a command), or so:LIBNAME (which package provides a shared
#     library, e.g. so:libssl.so.3) — mixed freely in one call.
#   apk-lookup.sh [--org ORG] search TERM [TERM...]   substring name search
#   The mode keywords exact, cmd, and so are also accepted as the first
#   argument and apply their prefix to every query:
#     apk-lookup.sh cmd useradd  ==  apk-lookup.sh cmd:useradd
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
# Dependencies: sh, docker (daemon running), timeout (GNU coreutils or
# BusyBox); chainctl only when --org is used. The script refuses to run
# docker without timeout: an unbounded pull or lookup can hang a migration.
# LOOKUP_IMAGE overrides the container (default cgr.dev/chainguard/wolfi-base:latest).

set -u

LOOKUP_IMAGE="${LOOKUP_IMAGE:-cgr.dev/chainguard/wolfi-base:latest}"
ORG=""

# Time bounds, from the workflow's stated limits: 10 minutes for a pull, and
# the same 10 minutes for the lookup run because it downloads the apk index
# over the network — the workflow's 60-second run bound is for local probes
# of already-built images, which this is not.
PULL_LIMIT=600
RUN_LIMIT=600

if [ "${1-}" = "--org" ]; then
  ORG="${2-}"
  [ -n "$ORG" ] || { echo "apk-lookup: --org needs a value" >&2; exit 2; }
  shift 2
fi

MODE="exact"
case "${1-}" in
  exact|search|cmd|so) MODE="$1"; shift ;;
esac
[ "$#" -ge 1 ] || { echo "usage: apk-lookup.sh [--org ORG] [exact|search|cmd|so] QUERY [QUERY...]" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || { echo "apk-lookup: docker not found" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "apk-lookup: the timeout utility (GNU coreutils or BusyBox) is required; refusing to run docker without a time bound" >&2; exit 1; }

# Queries are interpolated into a shell command inside the container, so
# restrict them to package/file-name characters, and require the first
# character to be a letter or digit: a query shaped like an option (--help,
# -e) would otherwise be parsed by apk — or docker — as an option, not a
# query. Rejecting here beats quoting games.
for q in "$@"; do
  case "$q" in
    '')
      echo "apk-lookup: empty query" >&2
      exit 2
      ;;
    [!A-Za-z0-9]*)
      echo "apk-lookup: query '$q' must start with a letter or digit (option-shaped queries are rejected)" >&2
      exit 2
      ;;
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

# LOOKUP_IMAGE is placed on the docker run command line, so it must look like
# an image reference; a value starting with '-' would become a docker option
# (LOOKUP_IMAGE=--privileged must never turn into docker run --privileged).
case "$LOOKUP_IMAGE" in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._:/@-]*)
    echo "apk-lookup: LOOKUP_IMAGE '$LOOKUP_IMAGE' is not an image reference (must start with a letter or digit and contain only [A-Za-z0-9._:/@-])" >&2
    exit 2
    ;;
esac

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

# Pull explicitly so the pull gets its own bound — an implicit pull inside
# docker run would run inside the (shorter-purposed) run bound instead.
docker image inspect "$LOOKUP_IMAGE" >/dev/null 2>&1 \
  || timeout "$PULL_LIMIT" docker pull -q "$LOOKUP_IMAGE" >/dev/null \
  || { echo "apk-lookup: could not pull $LOOKUP_IMAGE (failed or exceeded ${PULL_LIMIT}s)" >&2; exit 1; }

# Named container so a timed-out run can be removed: timeout kills the docker
# client, and the daemon-side container would otherwise keep running.
cname="apk-lookup-$$"
if [ -n "$ORG" ]; then
  timeout "$RUN_LIMIT" docker run --rm --name "$cname" -e HTTP_AUTH "$LOOKUP_IMAGE" sh -c "$inner"
else
  timeout "$RUN_LIMIT" docker run --rm --name "$cname" "$LOOKUP_IMAGE" sh -c "$inner"
fi
rc=$?
if [ "$rc" -eq 124 ]; then
  docker rm -f "$cname" >/dev/null 2>&1
  echo "apk-lookup: lookup container exceeded ${RUN_LIMIT}s and was stopped" >&2
  exit 1
fi
if [ "$rc" -eq 3 ]; then
  echo "apk-lookup: index update failed; results unavailable (not the same as NOT FOUND)" >&2
  exit 1
fi
exit "$rc"
