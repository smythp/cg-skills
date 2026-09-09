#!/bin/sh
# compare-images.sh — diff two local container images by packages, files, and
# shared libraries, without ever executing anything inside either image.
# Distroless images have no shell or package manager, so all inventory comes
# from the outside:
#   - packages:  SBOM scan of a `docker save` archive (syft binary if
#                installed, otherwise a syft container over the archive)
#   - files:     `docker create` + `docker export` + `tar -t` (create/export
#                never run the image)
#   - libraries: entries from the file listing matching shared-object names
#
# Usage: compare-images.sh ORIGINAL_IMAGE MIGRATED_IMAGE
#
# Environment:
#   SYFT_BIN    path to a syft binary (overrides lookup on PATH)
#   SYFT_IMAGE  syft container image for the fallback path (overrides the
#               pinned default below)
#
# Exit codes:
#   0 — all three comparisons were performed (differences are reported as
#       data, not as errors)
#   1 — a comparison could NOT be performed; the output says so explicitly.
#       Treat this as a failed validation gate, never as "no differences".
#   2 — usage error
#
# Dependencies: sh, awk, tar, sort, comm, docker (daemon running), timeout
# (GNU coreutils or BusyBox). The script refuses to run docker without
# timeout: an unbounded save or scan can hang the validation gate.

set -u

ORIG="${1-}"
MIGR="${2-}"
if [ -z "$ORIG" ] || [ -z "$MIGR" ]; then
  echo "usage: compare-images.sh ORIGINAL_IMAGE MIGRATED_IMAGE" >&2
  exit 2
fi

# The fallback scanner is pinned by digest so it cannot change under the
# skill. It is the upstream syft image because the fallback must be pullable
# with no Chainguard entitlement (cgr.dev/chainguard/syft is not in the free
# public catalog). To bump: pick a new tag, run
#   docker buildx imagetools inspect docker.io/anchore/syft:<tag>
# and replace both the tag and the sha256 below with what it prints.
SYFT_IMAGE="${SYFT_IMAGE:-docker.io/anchore/syft:v1.51.1@sha256:95fe0835e5bebc6f8b1f8acef68d47d63d594ef4c0f25c097ff853b23cbac74c}"
# 200 lines per diff list keeps output readable in an agent transcript while
# still naming every difference in the common case; counts are always exact.
LIST_CAP=200
# 10-minute bound on save and scan, matching the workflow's stated limits.
TIME_LIMIT=600

tmp="$(mktemp -d)" || { echo "compare-images: cannot create temp dir"; exit 1; }
chmod 700 "$tmp"
cleanup() {
  [ -n "${cid:-}" ] && docker rm -f "$cid" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

not_performed() {
  echo "compare-images: comparison was NOT performed: $1"
  echo "compare-images: do not treat this as an empty diff; the validation gate fails."
  exit 1
}

# Every save, pull, and scan runs under this bound; without the timeout
# utility the script fails closed rather than running docker unbounded.
command -v timeout >/dev/null 2>&1 || not_performed "the timeout utility (GNU coreutils or BusyBox) is missing; refusing to run unbounded docker save/pull/scan"
bounded() { timeout "$TIME_LIMIT" "$@"; }

command -v docker >/dev/null 2>&1 || not_performed "docker not found"
docker image inspect "$ORIG" >/dev/null 2>&1 || not_performed "image not present locally: $ORIG (docker pull or build it first)"
docker image inspect "$MIGR" >/dev/null 2>&1 || not_performed "image not present locally: $MIGR"

# --- resolve the SBOM scanner: binary first, container fallback -------------
SYFT_MODE=""
if [ -n "${SYFT_BIN:-}" ]; then
  if [ -x "$SYFT_BIN" ]; then
    SYFT_MODE="binary"
  fi
elif command -v syft >/dev/null 2>&1; then
  SYFT_BIN="$(command -v syft)"
  SYFT_MODE="binary"
elif [ -x /usr/local/bin/syft ]; then
  # Sandboxes commonly drop /usr/local/bin from PATH.
  SYFT_BIN=/usr/local/bin/syft
  SYFT_MODE="binary"
fi
if [ -z "$SYFT_MODE" ]; then
  if docker image inspect "$SYFT_IMAGE" >/dev/null 2>&1 || bounded docker pull -q "$SYFT_IMAGE" >/dev/null 2>&1; then
    SYFT_MODE="container"
  fi
fi
[ -n "$SYFT_MODE" ] || not_performed "no SBOM scanner: no syft binary on PATH or /usr/local/bin, and the fallback image $SYFT_IMAGE could not be pulled"

# scan IMAGE OUTFILE — write sorted name@version list
scan_packages() {
  img="$1"; out="$2"; base="$(basename "$out").tar"
  bounded docker save -o "$tmp/$base" "$img" || return 1
  if [ "$SYFT_MODE" = "binary" ]; then
    bounded "$SYFT_BIN" -q -o syft-table "docker-archive:$tmp/$base" > "$out.raw" || return 1
  else
    # Archive dir mounted read-only; nothing from the scanned image executes.
    # --user 0:0 so the scanner can read the 0700 temp dir regardless of the
    # image's default user; the mount stays read-only either way.
    bounded docker run --rm --user 0:0 -v "$tmp:/scan:ro" "$SYFT_IMAGE" -q -o syft-table "docker-archive:/scan/$base" > "$out.raw" || return 1
  fi
  # syft-table: NAME VERSION TYPE (header on line 1)
  awk 'NR > 1 && NF >= 2 { print $1 "@" $2 }' "$out.raw" | sort -u > "$out"
  rm -f "$tmp/$base"
  return 0
}

# list files of IMAGE into OUTFILE via create/export (never runs the image)
list_files() {
  img="$1"; out="$2"
  # The trailing argument is a placeholder command so create succeeds on
  # images with no CMD/ENTRYPOINT; the container is never started.
  cid=$(docker create "$img" placeholder-never-run 2>/dev/null) || return 1
  # Export to a file first so the export's own exit code is checkable.
  if ! bounded docker export -o "$tmp/export.tar" "$cid"; then
    docker rm -f "$cid" >/dev/null 2>&1
    return 1
  fi
  docker rm -f "$cid" >/dev/null 2>&1
  if ! tar -tf "$tmp/export.tar" > "$out.raw" 2>/dev/null; then
    rm -f "$tmp/export.tar"
    return 1
  fi
  sed 's:/$::' "$out.raw" | sort -u > "$out"
  rm -f "$tmp/export.tar" "$out.raw"
  return 0
}

print_diff() {
  label="$1"; a="$2"; b="$3"
  na=$(comm -23 "$a" "$b" | wc -l | tr -d ' ')
  nb=$(comm -13 "$a" "$b" | wc -l | tr -d ' ')
  echo ""
  echo "== $label =="
  echo "only in original ($na):"
  comm -23 "$a" "$b" | head -n "$LIST_CAP" | sed 's/^/  /'
  [ "$na" -gt "$LIST_CAP" ] && echo "  ... list capped at $LIST_CAP of $na"
  echo "only in migrated ($nb):"
  comm -13 "$a" "$b" | head -n "$LIST_CAP" | sed 's/^/  /'
  [ "$nb" -gt "$LIST_CAP" ] && echo "  ... list capped at $LIST_CAP of $nb"
}

echo "compare-images: original=$ORIG migrated=$MIGR"
if [ "$SYFT_MODE" = "binary" ]; then
  echo "compare-images: scanner: syft binary at $SYFT_BIN"
else
  echo "compare-images: scanner: syft container $SYFT_IMAGE"
fi

scan_packages "$ORIG" "$tmp/pkg-orig" || not_performed "SBOM scan failed for $ORIG"
scan_packages "$MIGR" "$tmp/pkg-migr" || not_performed "SBOM scan failed for $MIGR"
list_files "$ORIG" "$tmp/files-orig" || not_performed "file listing failed for $ORIG"
list_files "$MIGR" "$tmp/files-migr" || not_performed "file listing failed for $MIGR"

# Shared libraries: paths ending in .so or containing .so. anywhere —
# Guardener's isSharedLibrary rule. The suffix after .so. is not required to
# be numeric (libfoo.so.debug counts as much as libfoo.so.1.2).
grep -E '\.so($|\.)' "$tmp/files-orig" > "$tmp/libs-orig" || true
grep -E '\.so($|\.)' "$tmp/files-migr" > "$tmp/libs-migr" || true

print_diff "packages (name@version)" "$tmp/pkg-orig" "$tmp/pkg-migr"
print_diff "files" "$tmp/files-orig" "$tmp/files-migr"
print_diff "shared libraries" "$tmp/libs-orig" "$tmp/libs-migr"

echo ""
echo "compare-images: all three comparisons performed"
exit 0
