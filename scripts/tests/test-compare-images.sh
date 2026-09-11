#!/bin/sh
# Fixture tests for compare-images.sh. Needs Docker with egress to cgr.dev
# and registry.access.redhat.com. The setup pulls run under the same
# 10-minute bound the scripts use when a timeout binary (timeout or
# gtimeout) is installed, and unbounded when none is.
#
# Covers:
#   1. distroless vs glibc base (cgr.dev/chainguard/static vs wolfi-base) —
#      the distroless side must inventory without executing anything
#   2. an rpm-based UBI image — the scanner must read rpm databases too
#   3. no scanner available at all — the script must fail loudly with
#      "NOT performed", never print an empty diff
#   4. shared-library detection accepts any .so. suffix, not just numeric
#      ones (libfixture.so.debug), matching Guardener's isSharedLibrary
#   5. a sort that fails mid-inventory — the script must take the
#      NOT-performed path, never report an empty diff as complete
#   6. an option-shaped image argument (--help) — rejected before any
#      docker command runs
#   7. no timeout binary on PATH — the compare still exits 0 and prints
#      the no-timeout warning

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/compare-images.sh"

# TIMEOUT_BIN is timeout if present, else gtimeout (Homebrew coreutils on
# macOS installs it under that name), else empty.
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
else TIMEOUT_BIN=""
fi

# bounded SECONDS cmd args... — run under the timeout binary when one
# exists, and as given when none does.
bounded() {
  _secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k 30 "$_secs" "$@"
  else
    "$@"
  fi
}
STATIC=cgr.dev/chainguard/static:latest
GLIBC=cgr.dev/chainguard/wolfi-base:latest
UBI=registry.access.redhat.com/ubi8/ubi-minimal:latest

pass=0
failcount=0

ok()   { pass=$((pass + 1)); }
bad()  { failcount=$((failcount + 1)); echo "FAIL: $1"; }

for img in "$STATIC" "$GLIBC" "$UBI"; do
  docker image inspect "$img" >/dev/null 2>&1 || bounded 600 docker pull -q "$img" >/dev/null || {
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

echo "--- case 4: non-numeric .so suffix counts as a shared library ---"
# Build a minimal image by docker import (no build, no network) holding one
# versioned-with-words library and one plain .so; both must show up in the
# shared-libraries diff against static (which ships no .so files).
LIBIMG=compare-images-test-libs:fixture
fixdir="$(mktemp -d)" || exit 1
chmod 700 "$fixdir"
mkdir -p "$fixdir/usr/lib"
printf 'x' > "$fixdir/usr/lib/libfixture.so.debug"
printf 'x' > "$fixdir/usr/lib/libplain.so"
tar -C "$fixdir" -cf "$fixdir/root.tar" usr
docker import "$fixdir/root.tar" "$LIBIMG" >/dev/null 2>&1 || { echo "cannot docker import the library fixture; aborting"; rm -rf "$fixdir"; exit 1; }
out=$(sh "$SCRIPT" "$LIBIMG" "$STATIC" 2>&1); rc=$?
docker rmi -f "$LIBIMG" >/dev/null 2>&1
rm -rf "$fixdir"
if [ "$rc" -ne 0 ]; then
  bad "library fixture vs static exited $rc: $(echo "$out" | tail -3)"
else
  case "$out" in
    *libfixture.so.debug*) ok ;;
    *) bad "libfixture.so.debug missing from the shared-libraries diff (non-numeric .so suffix not detected)" ;;
  esac
  case "$out" in
    *libplain.so*) ok ;;
    *) bad "libplain.so missing from the shared-libraries diff" ;;
  esac
fi

echo "--- case 5: a failing sort mid-inventory takes the NOT-performed path ---"
# The shim passes the up-front presence check (command -v finds it) but fails
# when the inventory pipeline runs it; the gate must fail, not report an
# empty diff as three performed comparisons.
shimdir="$(mktemp -d)" || exit 1
chmod 700 "$shimdir"
printf '#!/bin/sh\nexit 1\n' > "$shimdir/sort"
chmod 755 "$shimdir/sort"
out=$(PATH="$shimdir:$PATH" sh "$SCRIPT" "$STATIC" "$GLIBC" 2>&1); rc=$?
rm -rf "$shimdir"
if [ "$rc" -eq 0 ]; then
  bad "failing-sort case exited 0; must fail"
else
  case "$out" in
    *"NOT performed"*) ok ;;
    *) bad "failing-sort case: message must say the comparison was NOT performed, got: $out" ;;
  esac
  case "$out" in
    *"all three comparisons performed"*) bad "failing-sort case printed the completion line" ;;
    *) ok ;;
  esac
fi

echo "--- case 6: an option-shaped image argument is rejected before docker runs ---"
# The docker shim fails loudly if invoked; the rejection must happen on
# argument validation alone.
shimdir="$(mktemp -d)" || exit 1
chmod 700 "$shimdir"
printf '#!/bin/sh\necho "docker invoked: $*" >&2\nexit 97\n' > "$shimdir/docker"
chmod 755 "$shimdir/docker"
out=$(PATH="$shimdir:$PATH" sh "$SCRIPT" --help "$GLIBC" 2>&1); rc=$?
rm -rf "$shimdir"
if [ "$rc" -eq 0 ]; then
  bad "--help as ORIGINAL_IMAGE exited 0; must be rejected"
else
  case "$out" in
    *"'--help' is not an image reference"*) ok ;;
    *) bad "--help rejection must name the bad argument, got: $out" ;;
  esac
  case "$out" in
    *"docker invoked:"*) bad "--help case ran docker before validating: $out" ;;
    *) ok ;;
  esac
fi

echo "--- case 7: no timeout binary still compares, with a warning ---"
# A shim PATH holding every dependency except timeout and gtimeout: the
# compare must print the no-timeout line, run unbounded, and still perform
# all three comparisons. The syft binary fallback at /usr/local/bin/syft or
# the scanner container keeps a scanner reachable without PATH.
shimdir="$(mktemp -d)" || exit 1
chmod 700 "$shimdir"
for dep in awk basename chmod comm docker grep head mktemp rm sed sort tar tr wc sh; do
  p="$(command -v "$dep")" || { echo "cannot resolve $dep for the shim PATH; aborting"; rm -rf "$shimdir"; exit 1; }
  ln -s "$p" "$shimdir/$dep"
done
out=$(PATH="$shimdir" "$shimdir/sh" "$SCRIPT" "$STATIC" "$GLIBC" 2>&1); rc=$?
rm -rf "$shimdir"
if [ "$rc" -ne 0 ]; then
  bad "no-timeout case exited $rc: $(echo "$out" | tail -3)"
else
  case "$out" in
    *"no timeout binary found"*) ok ;;
    *) bad "no-timeout case must print the no-timeout warning, got: $(echo "$out" | head -3)" ;;
  esac
  case "$out" in
    *"all three comparisons performed"*) ok ;;
    *) bad "no-timeout case: missing completion line" ;;
  esac
fi

echo ""
echo "test-compare-images: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
