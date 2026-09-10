#!/bin/sh
# Fixture tests for preflight.sh, driven through command shims so no real
# docker daemon or chainctl login is needed.
#
# Covers:
#   1. chainctl that exits 0 with empty output on the organization listing —
#      preflight must report LISTING FAILED and exit non-zero, never read it
#      as "no organizations"
#   2. a working listing (minimal JSON) — preflight must PASS and show the
#      organization
#
# Dependencies: sh, awk, grep, sed, sort, timeout (all also required by
# preflight itself). No network, no Docker, no chainctl.

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/preflight.sh"
tmp="$(mktemp -d)" || exit 1
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
failcount=0

ok()   { pass=$((pass + 1)); }
bad()  { failcount=$((failcount + 1)); echo "FAIL: $1"; }

# Shim dir goes first on PATH; /usr/local/bin follows so preflight's own
# PATH-extension case matches and does not prepend it AHEAD of the shims.
mkdir -p "$tmp/bin"

# Shimmed docker: preflight only calls `docker info` and `docker version`.
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "${1-}" in
  info) exit 0 ;;
  version) echo "0.0.0-shim"; exit 0 ;;
esac
exit 0
EOF
chmod 755 "$tmp/bin/docker"

# Two chainctl shims: auth status always succeeds; the organization listing
# either prints nothing (exit 0 — the lie case 1 exists for) or a minimal
# JSON list.
cat > "$tmp/chainctl-empty" <<'EOF'
#!/bin/sh
if [ "${1-}" = "auth" ]; then echo "  Email | shim@example.com"; exit 0; fi
exit 0
EOF
cat > "$tmp/chainctl-json" <<'EOF'
#!/bin/sh
if [ "${1-}" = "auth" ]; then echo "  Email | shim@example.com"; exit 0; fi
printf '[{"name":"shim-org"}]\n'
exit 0
EOF

echo "--- case 1: listing exits 0 with empty output fails preflight ---"
cp "$tmp/chainctl-empty" "$tmp/bin/chainctl"
chmod 755 "$tmp/bin/chainctl"
out=$(PATH="$tmp/bin:/usr/local/bin:$PATH" sh "$SCRIPT" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "empty listing passed preflight: $out"
else
  case "$out" in
    *"empty or not JSON"*) ok ;;
    *) bad "empty listing must be reported as empty-or-not-JSON, got: $out" ;;
  esac
fi

echo "--- case 2: minimal JSON listing passes ---"
cp "$tmp/chainctl-json" "$tmp/bin/chainctl"
chmod 755 "$tmp/bin/chainctl"
out=$(PATH="$tmp/bin:/usr/local/bin:$PATH" sh "$SCRIPT" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "JSON listing case exited $rc: $out"
else
  case "$out" in
    *"shim-org"*) ok ;;
    *) bad "organization shim-org missing from output: $out" ;;
  esac
  case "$out" in
    *"preflight: PASS"*) ok ;;
    *) bad "expected 'preflight: PASS', got: $out" ;;
  esac
fi

echo ""
echo "test-preflight: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
