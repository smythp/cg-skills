#!/bin/sh
# Live tests for check-from-oracle.sh. Needs Docker with buildx and egress to
# cgr.dev and docker.io, like test-compare-images.sh; the script's outline
# calls load registry metadata and execute nothing.
#
# Covers:
#   1. the two FROM-gate bypasses from the second review round — a heredoc
#      marker hidden in a quoted string, and a fallback FROM fed by an
#      automatic platform argument. The oracle rejects both regardless of
#      how the textual parser reads them, because it asks BuildKit itself.
#   2. a multi-stage file whose runtime stage is cgr.dev/chainguard/static —
#      every resolved base allowed, exit 0
#   3. a file whose only external base sits on a configured mirror prefix —
#      allowed with --mirror, rejected without
#   4. a file whose base cannot resolve — exit 1 and an explicit
#      not-a-pass message, never a pass

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-from-oracle.sh"
tmp="$(mktemp -d)" || exit 1
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
failcount=0
ok()  { pass=$((pass + 1)); }
bad() { failcount=$((failcount + 1)); echo "FAIL: $1"; }

echo "--- case 1a: quoted heredoc marker bypass ---"
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo " <<EOT "
FROM alpine
RUN <<EOT
echo hi
EOT
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "quoted heredoc marker: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine"*) ok ;;
    *) bad "quoted heredoc marker: should reject alpine, got: $out" ;;
  esac
fi

echo "--- case 1b: automatic platform argument bypass ---"
cat > "$tmp/Dockerfile" <<'EOF'
ARG BASE=${TARGETARCH:+alpine}
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
RUN echo hi
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "platform argument bypass: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine"*) ok ;;
    *) bad "platform argument bypass: should reject alpine, got: $out" ;;
  esac
fi

echo "--- case 2: multi-stage file on the allowlist ---"
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo build
FROM cgr.dev/chainguard/static:latest
COPY --from=builder /etc/os-release /os-release
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "multi-stage allowlist: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/static:latest"*) ok ;;
    *) bad "multi-stage allowlist: should name the static base as allowed, got: $out" ;;
  esac
fi

echo "--- case 3: mirror prefix ---"
cat > "$tmp/Dockerfile" <<'EOF'
FROM docker.io/library/busybox:latest
RUN echo hi
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "mirror prefix without --mirror: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/busybox"*) ok ;;
    *) bad "mirror prefix without --mirror: should reject busybox, got: $out" ;;
  esac
fi
out=$(sh "$SCRIPT" --mirror docker.io/library "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "mirror prefix with --mirror: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  docker.io/library/busybox"*) ok ;;
    *) bad "mirror prefix with --mirror: should allow busybox, got: $out" ;;
  esac
fi

echo "--- case 4: unresolvable base is not a pass ---"
cat > "$tmp/Dockerfile" <<'EOF'
FROM resolv-fail.invalid/image:latest
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "unresolvable base: expected exit 1, got a pass"
else
  case "$out" in
    *"not a pass"*) ok ;;
    *) bad "unresolvable base: should say it is not a pass, got: $out" ;;
  esac
fi

echo ""
echo "test-check-from-oracle: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
