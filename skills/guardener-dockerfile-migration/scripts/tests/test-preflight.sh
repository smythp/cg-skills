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
#   3. a PATH with neither timeout nor gtimeout — preflight exits 0 and
#      prints the not-found line (a warning, not a failure)
#   4. a PATH where only gtimeout exists — preflight prints OK (gtimeout)
#   5. a context holding Dockerfile.dockerignore — preflight reports the
#      Dockerfile-specific ignore file and that it must travel beside the
#      relocated temporary Dockerfile; still a PASS, never a failure
#
# Dependencies: sh, awk, grep, sed, sort. No network, no Docker, no
# chainctl.

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
# either prints nothing (exit 0 — the case 1 checks) or a minimal
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

# Cases 3 and 4 need a PATH that controls whether timeout and gtimeout
# resolve, so the shim directory carries preflight's other dependencies
# itself. preflight prepends /usr/local/bin to PATH when it is absent, which
# would let a host's own timeout or gtimeout there (Homebrew on Intel macOS)
# change what these cases see; so they run a copy of preflight whose
# /usr/local/bin is rewritten to an empty directory under $tmp.
SH_BIN="$(command -v sh)"
mkdir -p "$tmp/emptybin"
PF_ISOLATED="$tmp/preflight-isolated.sh"
sed "s|/usr/local/bin|$tmp/emptybin|g" "$SCRIPT" > "$PF_ISOLATED"
make_tool_shims() {
  mkdir -p "$1"
  for t in awk grep sed sort; do
    p="$(command -v "$t")" || { echo "cannot resolve $t for the shim PATH; aborting"; exit 1; }
    ln -s "$p" "$1/$t"
  done
  cp "$tmp/bin/docker" "$1/docker"
  cp "$tmp/chainctl-json" "$1/chainctl"
  chmod 755 "$1/docker" "$1/chainctl"
}

echo "--- case 3: neither timeout nor gtimeout is a warning, not a failure ---"
make_tool_shims "$tmp/notimeout"
out=$(PATH="$tmp/notimeout" "$SH_BIN" "$PF_ISOLATED" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "a missing timeout binary must not fail preflight (exited $rc): $out"
else
  case "$out" in
    *"timeout: not found"*) ok ;;
    *) bad "expected the timeout not-found line, got: $out" ;;
  esac
fi

echo "--- case 4: gtimeout alone reports OK (gtimeout) ---"
make_tool_shims "$tmp/gtimeoutonly"
printf '#!/bin/sh\nexit 0\n' > "$tmp/gtimeoutonly/gtimeout"
chmod 755 "$tmp/gtimeoutonly/gtimeout"
out=$(PATH="$tmp/gtimeoutonly" "$SH_BIN" "$PF_ISOLATED" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "gtimeout-only case exited $rc: $out"
else
  case "$out" in
    *"timeout: OK (gtimeout)"*) ok ;;
    *) bad "expected 'timeout: OK (gtimeout)', got: $out" ;;
  esac
fi

echo "--- case 5: a Dockerfile-specific ignore file is reported ---"
mkdir -p "$tmp/ctx-di"
printf 'secret.txt\n' > "$tmp/ctx-di/Dockerfile.dockerignore"
cp "$tmp/chainctl-json" "$tmp/bin/chainctl"
chmod 755 "$tmp/bin/chainctl"
out=$(PATH="$tmp/bin:/usr/local/bin:$PATH" sh "$SCRIPT" "$tmp/ctx-di" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "a Dockerfile-specific ignore file must not fail preflight (exited $rc): $out"
else
  case "$out" in
    *"Dockerfile-specific ignore file: Dockerfile.dockerignore"*) ok ;;
    *) bad "expected the Dockerfile-specific ignore file report, got: $out" ;;
  esac
  case "$out" in
    *"travel beside the temporary file"*) ok ;;
    *) bad "the report must say the file travels beside the temporary Dockerfile, got: $out" ;;
  esac
fi

echo ""
echo "test-preflight: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
