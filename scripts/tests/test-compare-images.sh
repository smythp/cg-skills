#!/bin/sh
# Fixture tests for compare-images.sh. Needs Docker with egress to cgr.dev
# and registry.access.redhat.com.
#
# Covers:
#   1. distroless vs glibc base (cgr.dev/chainguard/static vs wolfi-base) —
#      the distroless side must inventory without executing anything
#   2. an rpm-based UBI image — the scanner must read rpm databases too
#   3. no scanner available at all — the script must fail loudly with
#      "NOT performed", never print an empty diff

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/compare-images.sh"
STATIC=cgr.dev/chainguard/static:latest
GLIBC=cgr.dev/chainguard/wolfi-base:latest
UBI=registry.access.redhat.com/ubi8/ubi-minimal:latest

pass=0
failcount=0

ok()   { pass=$((pass + 1)); }
bad()  { failcount=$((failcount + 1)); echo "FAIL: $1"; }

for img in "$STATIC" "$GLIBC" "$UBI"; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null || {
    echo "cannot pull $img; aborting"; exit 1; }
done

echo "--- case 1: distroless vs glibc base ---"
out=$(sh "$SCRIPT" "$STATIC" "$GLIBC" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "static vs wolfi-base exited $rc: $(echo "$out" | tail -3)"
else
  case "$out" in
    *"all three comparisons performed"*) ok ;;
    *) bad "static vs wolfi-base: missing completion line" ;;
  esac
  # wolfi-base has busybox and apk-tools; static must not.
  case "$out" in
    *busybox*) ok ;;
    *) bad "static vs wolfi-base: expected busybox in the migrated-only package diff" ;;
  esac
fi

echo "--- case 2: rpm-based UBI image ---"
out=$(sh "$SCRIPT" "$UBI" "$GLIBC" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "ubi-minimal vs wolfi-base exited $rc: $(echo "$out" | tail -3)"
else
  # ubi-minimal carries rpm-packaged glibc etc.; the original-only package
  # list must be non-empty (i.e. the rpm database was actually read).
  n=$(echo "$out" | awk '/== packages/{f=1} f && /only in original \(/ {gsub(/[^0-9]/,"",$0); print; exit}')
  if [ -n "$n" ] && [ "$n" -gt 0 ]; then ok; else bad "ubi-minimal: rpm packages not inventoried (original-only count: ${n:-none})"; fi
fi

echo "--- case 3: no scanner available fails loudly ---"
out=$(SYFT_BIN=/nonexistent/syft SYFT_IMAGE=localhost/absent-syft:none sh "$SCRIPT" "$STATIC" "$GLIBC" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "no-scanner case exited 0; must fail"
else
  case "$out" in
    *"NOT performed"*) ok ;;
    *) bad "no-scanner case: message must say the comparison was NOT performed, got: $out" ;;
  esac
fi

echo ""
echo "test-compare-images: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
