#!/bin/sh
# Tests for check-from-oracle.sh, in two parts.
#
# The live cases need Docker with buildx and egress to cgr.dev and docker.io,
# like test-compare-images.sh; the script's outline calls load registry
# metadata and execute nothing. They cover:
#   1. the FROM-gate bypasses from review: a heredoc marker hidden in a
#      quoted string, a fallback FROM fed by an automatic platform argument,
#      and a --platform spelling (linux/amd64/v1) whose variant a real build
#      normalizes away. The oracle rejects all three regardless of how the
#      textual parser reads them, because it asks BuildKit itself.
#   2. a multi-stage file whose runtime stage is cgr.dev/chainguard/static —
#      every resolved base allowed, exit 0
#   3. a file whose only external base sits on a configured mirror prefix —
#      allowed with --mirror, rejected without
#   4. a file whose base cannot resolve — exit 1 and an explicit
#      not-a-pass message, never a pass
#   5. --build-platform: the BUILD* overrides reach the frontend (the run
#      names alpine:b-arm64, not the daemon's own architecture)
#
# The shim cases need no container engine: a docker shim on PATH prints
# canned output (and a timeout shim shortens the bound), pinning the exit
# status for empty output, unrelated output, a bracketed-label reference
# line that must be REJECTED, an unparsable reference line, a scratch-only
# success with evidence, runs missing either evidence marker, a nonzero
# docker exit, a timed-out run, a configured source policy, and a context
# directory named --help, whose name must reach docker as a path after --,
# never as an option.

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

echo "--- case 1c: amd64/v1 platform normalization bypass ---"
cat > "$tmp/Dockerfile" <<'EOF'
ARG BASE=${TARGETVARIANT:+cgr.dev/chainguard/wolfi-base}
FROM ${BASE:-alpine}
RUN echo hi
EOF
out=$(sh "$SCRIPT" --platform linux/amd64/v1 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "amd64/v1 normalization: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine"*) ok ;;
    *) bad "amd64/v1 normalization: should reject alpine, got: $out" ;;
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

echo "--- case 5: --build-platform override reaches the frontend ---"
# The BUILD* overrides must reach BuildKit: on this daemon the natural
# BUILDARCH is the daemon's own architecture, so only an applied override
# makes the frontend resolve alpine:b-arm64. That tag does not exist, so
# the run fails naming it (and if it ever existed, the REJECTED line would
# name it instead); either way the ref in the output is the proof.
cat > "$tmp/Dockerfile" <<'EOF'
FROM alpine:b-${BUILDARCH}
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 --build-platform linux/arm64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "build-platform override: expected a failing run, got a pass"
else
  case "$out" in
    *"alpine:b-arm64"*) ok ;;
    *) bad "build-platform override: the output should name alpine:b-arm64, got: $out" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Shim cases: no container engine. A docker shim on PATH prints the canned
# output named by SHIM_OUT, logs its arguments to SHIM_ARGS, sleeps
# SHIM_SLEEP, and exits SHIM_RC; a timeout shim re-bounds the script's
# timeout call at 2 seconds so the timed-out case finishes quickly.
# ---------------------------------------------------------------------------

shimdir="$tmp/shim"
mkdir -p "$shimdir"
real_timeout=$(command -v timeout || command -v gtimeout)
cat > "$shimdir/docker" <<'EOF'
#!/bin/sh
[ -n "${SHIM_ARGS:-}" ] && printf '%s\n' "$@" >> "$SHIM_ARGS"
[ -n "${SHIM_SLEEP:-}" ] && exec sleep "$SHIM_SLEEP"
[ -n "${SHIM_OUT:-}" ] && cat "$SHIM_OUT"
exit "${SHIM_RC:-0}"
EOF
chmod 755 "$shimdir/docker"
cat > "$shimdir/timeout" <<EOF
#!/bin/sh
# check-from-oracle.sh calls: timeout -k GRACE LIMIT docker ...
shift 3
exec "$real_timeout" -k 2 2 "\$@"
EOF
chmod 755 "$shimdir/timeout"

# shim_case NAME OUTFILE RC EXPECT CONTAINS [ARG...]: run the oracle against
# the shim with SHIM_OUT=OUTFILE and SHIM_RC=RC; EXPECT is the expected exit
# (0 or 1) and CONTAINS a string the output must hold.
shim_case() {
  sc_name="$1"; sc_out="$2"; sc_rc="$3"; sc_expect="$4"; sc_contains="$5"; shift 5
  out=$(SHIM_OUT="$sc_out" SHIM_RC="$sc_rc" PATH="$shimdir:$PATH" \
        sh "$SCRIPT" "$@" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
  if [ "$rc" -ne "$sc_expect" ]; then
    bad "$sc_name: expected exit $sc_expect, got $rc: $out"
    return
  fi
  case "$out" in
    *"$sc_contains"*) ok ;;
    *) bad "$sc_name: output should contain '$sc_contains', got: $out" ;;
  esac
}

cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

# Canned outputs, shaped like real buildx 0.37 plain-progress runs with the
# outline JSON result on stdout (verified against real runs; the JSON
# "sources" object prints for every file, named target stage or not).
cat > "$tmp/out-good" <<'EOF'
#0 building with "default" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 84B done
#1 DONE 0.0s

#2 [internal] load metadata for cgr.dev/chainguard/wolfi-base:latest
#2 DONE 0.1s
{
  "sources": [
    "RlJPTQo="
  ]
}
EOF

sed 's/^#2 DONE.*/#3 [linux\/amd64 internal] load metadata for docker.io\/library\/alpine:latest/' \
  "$tmp/out-good" > "$tmp/out-mixed"

grep -v 'load metadata for' "$tmp/out-good" > "$tmp/out-scratch"

cat > "$tmp/out-unrelated" <<'EOF'
Usage:  docker buildx build [OPTIONS] PATH | URL | -

Start a build

Options:
      --add-host strings   Add a custom host-to-IP mapping
EOF

grep -v 'load build definition' "$tmp/out-good" > "$tmp/out-nodef"

grep -v '"sources"' "$tmp/out-good" > "$tmp/out-nojson"

sed 's/^#2 DONE.*/#4 [internal] load metadata for two tokens/' \
  "$tmp/out-good" > "$tmp/out-unparsable"

: > "$tmp/out-empty"

echo "--- shim cases ---"
shim_case "empty output" "$tmp/out-empty" 0 1 "no evidence"
shim_case "unrelated output" "$tmp/out-unrelated" 0 1 "no evidence"
shim_case "bracketed-label reference is rejected" "$tmp/out-mixed" 0 1 \
  "REJECTED docker.io/library/alpine:latest"
shim_case "allowed reference passes" "$tmp/out-good" 0 0 \
  "allowed  cgr.dev/chainguard/wolfi-base:latest"
shim_case "scratch-only success with evidence passes" "$tmp/out-scratch" 0 0 \
  "resolve no external base images"
shim_case "missing load-build-definition step fails" "$tmp/out-nodef" 0 1 "no evidence"
shim_case "missing outline JSON result fails" "$tmp/out-nojson" 0 1 "no evidence"
shim_case "unparsable reference line fails naming it" "$tmp/out-unparsable" 0 1 \
  "load metadata for two tokens"
shim_case "nonzero docker exit fails" "$tmp/out-good" 3 1 "outline run failed (exit 3)"

echo "--- shim case: timed-out run ---"
out=$(SHIM_SLEEP=10 PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "timed-out run: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"not a pass"*) ok ;;
    *) bad "timed-out run: should say it is not a pass, got: $out" ;;
  esac
fi

echo "--- shim case: source policy in the environment ---"
out=$(EXPERIMENTAL_BUILDKIT_SOURCE_POLICY="$tmp/policy.json" PATH="$shimdir:$PATH" \
      sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "source policy: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"EXPERIMENTAL_BUILDKIT_SOURCE_POLICY"*) ok ;;
    *) bad "source policy: should name the variable, got: $out" ;;
  esac
fi

echo "--- shim case: context directory named --help ---"
mkdir -p "$tmp/--help"
argslog="$tmp/argslog"
: > "$argslog"
out=$(cd "$tmp" && SHIM_OUT="$tmp/out-unrelated" SHIM_ARGS="$argslog" PATH="$shimdir:$PATH" \
      sh "$SCRIPT" Dockerfile --help 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "--help context: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"no evidence"*) ok ;;
    *) bad "--help context: should fail for lack of evidence, got: $out" ;;
  esac
fi
if grep -qx -- '--help' "$argslog"; then
  bad "--help context: a bare --help argument reached docker: $(cat "$argslog")"
else
  ok
fi
if grep -qx -- '--' "$argslog" && grep -qxF -- "$tmp/--help" "$argslog"; then
  ok
else
  bad "--help context: docker should get -- then the absolute context path, got: $(cat "$argslog")"
fi

echo ""
echo "test-check-from-oracle: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
