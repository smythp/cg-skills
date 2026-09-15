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
#      every base allowed, exit 0
#   3. a file whose only external base sits on a configured mirror prefix —
#      allowed with --mirror, rejected without
#   4. an off-allowlist base is rejected from the stage graph without any
#      resolution, and an allowed base that fails to resolve is an
#      explicit not-a-pass, never a pass
#   5. --build-platform: the BUILD* overrides reach the frontend (the
#      failing run names the b-arm64 tag, not the daemon's own
#      architecture)
#   6. a named build context that overrides a Chainguard FROM to alpine —
#      the substituted base is rejected in canonical form, and the same
#      override pointed at another Chainguard image passes
#   7. artifact sources: COPY --from and RUN --mount=from references are
#      printed as external artifact sources and allowed, and a reference
#      that is both a base and a copy source is rejected as a base
#   9. a named context matching a stage's AS name replaces that stage's
#      base at the definition, so the substituted reference is what meets
#      the allowlist, with reference normalization on the context name
#  10. context names keep their registry host case and compare byte-exact,
#      so an uppercase-host spelling matches nothing
#
# The shim cases need no container engine: a docker shim on PATH prints
# canned output per call (targets and outline separately, and a timeout
# shim shortens the bound), pinning the exit
# status for empty output, unrelated output, a bracketed-label load that
# must classify as an artifact source, an unparsable reference line, a
# scratch-only stage graph, an off-allowlist stage, an alias base, a JSON
# escape in a base, targets runs that fail or lack evidence, outline runs
# missing either evidence marker, a nonzero
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

echo "--- case 1d: declared default for an automatic argument is rejected ---"
# The pull-request reproduction. The real build keeps the single-quoted
# default literal, so TARGETVARIANT is set and non-empty, BASE becomes
# alpine, and alpine is pulled, while the script's synthetic TARGETVARIANT
# override would empty it and resolve wolfi-base. The scan rejects the
# declaration before the outline runs, under both platforms.
cat > "$tmp/Dockerfile" <<'EOF'
ARG TARGETVARIANT='${UNSET}'
ARG BASE=${TARGETVARIANT:+alpine}
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
EOF
for plat in linux/amd64 linux/arm64; do
  out=$(sh "$SCRIPT" --platform "$plat" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "declared automatic default ($plat): expected rejection, got a pass"
  else
    case "$out" in
      *"declares a default for the automatic argument TARGETVARIANT"*) ok ;;
      *) bad "declared automatic default ($plat): should name TARGETVARIANT, got: $out" ;;
    esac
  fi
done

echo "--- case 1e: single-quoted ARG default stays literal in the frontend ---"
# BuildKit keeps the single-quoted default literal (verified by this very
# run), so X is set and non-empty, B becomes the wolfi-base reference, and
# the outline resolves cgr.dev/chainguard/wolfi-base:latest. A frontend
# that expanded inside single quotes would resolve alpine and fail the run.
cat > "$tmp/Dockerfile" <<'EOF'
ARG X='${UNSET}'
ARG B=${X:+cgr.dev/chainguard/wolfi-base}
FROM ${B:-docker.io/library/alpine}
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "single-quoted literal default: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/wolfi-base:latest"*) ok ;;
    *) bad "single-quoted literal default: should allow wolfi-base, got: $out" ;;
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

echo "--- case 4: off-allowlist base with an unresolvable host is rejected ---"
# The FROM set comes from the targets call, which resolves nothing, so an
# off-allowlist base is rejected in canonical form before any resolution.
cat > "$tmp/Dockerfile" <<'EOF'
FROM resolv-fail.invalid/image:latest
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "unresolvable off-allowlist base: expected exit 1, got a pass"
else
  case "$out" in
    *"REJECTED resolv-fail.invalid/image:latest"*) ok ;;
    *) bad "unresolvable off-allowlist base: should reject it by name, got: $out" ;;
  esac
fi

echo "--- case 4b: an allowed base that fails to resolve is not a pass ---"
# The FROM set passes (cgr.dev), so the outline runs and fails on the
# missing image; a resolution failure is never a pass.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/no-such-image-zqxw:latest
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "unresolvable allowed base: expected exit 1, got a pass"
else
  case "$out" in
    *"not a pass"*) ok ;;
    *) bad "unresolvable allowed base: should say it is not a pass, got: $out" ;;
  esac
fi

echo "--- case 5: --build-platform override reaches the frontend ---"
# The BUILD* overrides must reach BuildKit: on this daemon the natural
# BUILDARCH is the daemon's own architecture, so only an applied override
# makes the frontend resolve the b-arm64 reference. The base is on the
# allowlist, so the FROM set passes and the outline runs; the tag does not
# exist, so the run fails naming it, and the named ref is the proof the
# override reached the frontend.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base:b-${BUILDARCH}
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 --build-platform linux/arm64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "build-platform override: expected a failing run, got a pass"
else
  case "$out" in
    *"b-arm64"*) ok ;;
    *) bad "build-platform override: the output should name the b-arm64 tag, got: $out" ;;
  esac
fi

echo "--- case 6: named build context override ---"
# The pull-request reproduction. The override makes the Chainguard FROM
# resolve to alpine; the progress line has the [context NAME] label and the
# label-agnostic parsing must reject its reference. The same override
# pointed at another Chainguard image must pass.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF
out=$(sh "$SCRIPT" --build-context cgr.dev/chainguard/wolfi-base=docker-image://alpine:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "context override to alpine: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "context override to alpine: should reject alpine in canonical form, got: $out" ;;
  esac
fi
out=$(sh "$SCRIPT" --build-context cgr.dev/chainguard/wolfi-base=docker-image://cgr.dev/chainguard/static:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "context override to static: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/static:latest"*) ok ;;
    *) bad "context override to static: should allow static, got: $out" ;;
  esac
fi

echo "--- case 7: artifact sources are reported, not rejected ---"
# The pull-request reproduction. COPY --from and RUN --mount=from name
# external artifact sources, which the registry rules permit as report
# entries; only FROM bases meet the allowlist. A reference that is both a
# base and a copy source is a base and is rejected.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/static:latest
COPY --from=busybox:latest /bin/busybox /busybox
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "copy artifact source: expected pass, exit $rc: $out"
else
  case "$out" in
    *"external artifact source docker.io/library/busybox:latest"*) ok ;;
    *) bad "copy artifact source: should report busybox as an artifact source, got: $out" ;;
  esac
fi
cat > "$tmp/Dockerfile" <<'EOF'
FROM alpine
COPY --from=alpine /etc/os-release /o
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "base doubling as copy source: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "base doubling as copy source: should reject alpine as a base, got: $out" ;;
  esac
fi
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=from=alpine,target=/mnt echo hi
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "mount artifact source: expected pass, exit $rc: $out"
else
  case "$out" in
    *"external artifact source docker.io/library/alpine:latest"*) ok ;;
    *) bad "mount artifact source: should report alpine as an artifact source, got: $out" ;;
  esac
fi

echo "--- case 9: named context at the stage definition ---"
# BuildKit applies a context whose name matches a stage's AS name at the
# stage's definition, replacing the stage's base even when no FROM
# references the name (outline: only alpine:latest loads, under [context
# builder], and wolfi-base is never touched). The substituted base enters
# the FROM set and is rejected there in canonical form; pointed at another
# Chainguard image it passes, with the [context builder] load matching the
# set. Reference normalization applies to the context name, so the
# docker.io/library/builder spelling overrides the same stage.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo hi
EOF
out=$(sh "$SCRIPT" --build-context builder=docker-image://alpine:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "stage-name context to alpine: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "stage-name context to alpine: should reject alpine in canonical form, got: $out" ;;
  esac
fi
out=$(sh "$SCRIPT" --build-context builder=docker-image://cgr.dev/chainguard/static:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "stage-name context to static: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/static:latest"*) ok ;;
    *) bad "stage-name context to static: should allow static, got: $out" ;;
  esac
fi
out=$(sh "$SCRIPT" --build-context docker.io/library/builder=docker-image://alpine:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "normalized stage-name context: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "normalized stage-name context: should reject alpine, got: $out" ;;
  esac
fi

echo "--- case 10: registry host case in context matching ---"
# BuildKit keeps the domain case from splitDockerDomain and compares hosts
# byte-exact: the DOCKER.io spelling is accepted by buildx but matches
# nothing (outline: docker.io/library/alpine:latest loads under
# [internal]), so alpine stays the base and is rejected; the all-lowercase
# spelling matches and substitutes static (outline: static loads under
# [context alpine]).
cat > "$tmp/Dockerfile" <<'EOF'
FROM alpine
RUN echo hi
EOF
out=$(sh "$SCRIPT" --build-context DOCKER.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "uppercase-host context: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "uppercase-host context: should reject alpine, got: $out" ;;
  esac
fi
out=$(sh "$SCRIPT" --build-context docker.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "lowercase-host context: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/static:latest"*) ok ;;
    *) bad "lowercase-host context: should allow static, got: $out" ;;
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
# The docker shim answers the script's two buildx calls separately: the
# targets call gets SHIM_OUT_TARGETS and exits SHIM_RC_TARGETS, everything
# else gets SHIM_OUT and exits SHIM_RC.
cat > "$shimdir/docker" <<'EOF'
#!/bin/sh
[ -n "${SHIM_ARGS:-}" ] && printf '%s\n' "$@" >> "$SHIM_ARGS"
[ -n "${SHIM_SLEEP:-}" ] && exec sleep "$SHIM_SLEEP"
case " $* " in
  *" --call=targets,format=json "*)
    [ -n "${SHIM_OUT_TARGETS:-}" ] && cat "$SHIM_OUT_TARGETS"
    exit "${SHIM_RC_TARGETS:-0}"
    ;;
esac
[ -n "${SHIM_OUT:-}" ] && cat "$SHIM_OUT"
exit "${SHIM_RC:-0}"
EOF
chmod 755 "$shimdir/docker"
# The timeout shim re-bounds the script's timeout call at 2 seconds so the
# timed-out case finishes quickly. It resolves the real binary with the
# same three tiers as the scripts (timeout, then gtimeout, then none); with
# neither installed the shim runs the command unbounded, and the timed-out
# case then waits out the shim sleep and fails on the empty output instead.
# The absolute path matters: the shim itself is named timeout and sits
# first on PATH, so exec of the bare name would loop on the shim forever.
if command -v timeout >/dev/null 2>&1; then real_timeout=$(command -v timeout)
elif command -v gtimeout >/dev/null 2>&1; then real_timeout=$(command -v gtimeout)
else real_timeout=""
fi
if [ -n "$real_timeout" ]; then
  cat > "$shimdir/timeout" <<EOF
#!/bin/sh
# check-from-oracle.sh calls: timeout -k GRACE LIMIT docker ...
shift 3
exec "$real_timeout" -k 2 2 "\$@"
EOF
else
  cat > "$shimdir/timeout" <<'EOF'
#!/bin/sh
# no timeout binary on this machine; run the command unbounded
shift 3
exec "$@"
EOF
fi
chmod 755 "$shimdir/timeout"

# shim_case NAME OUTFILE RC EXPECT CONTAINS [ARG...]: run the oracle against
# the shim with SHIM_OUT=OUTFILE and SHIM_RC=RC for the outline call; the
# targets call answers with $sc_targets (out-targets-good unless a case
# sets it) and exits ${sc_targets_rc:-0}. EXPECT is the expected exit
# (0 or 1) and CONTAINS a string the output must hold.
shim_case() {
  sc_name="$1"; sc_out="$2"; sc_rc="$3"; sc_expect="$4"; sc_contains="$5"; shift 5
  out=$(SHIM_OUT="$sc_out" SHIM_RC="$sc_rc" \
        SHIM_OUT_TARGETS="${sc_targets:-$tmp/out-targets-good}" \
        SHIM_RC_TARGETS="${sc_targets_rc:-0}" PATH="$shimdir:$PATH" \
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
# JSON result on stdout (verified against real runs; the JSON prints for
# every file, named target stage or not; inside each target "name" comes
# before "base").
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

cat > "$tmp/out-targets-good" <<'EOF'
#0 building with "default" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 84B done
#1 DONE 0.0s
{
  "targets": [
    {
      "default": true,
      "base": "cgr.dev/chainguard/wolfi-base",
      "location": {
        "ranges": [
          {
            "start": {
              "line": 1
            },
            "end": {
              "line": 1
            }
          }
        ]
      }
    }
  ],
  "sources": [
    "RlJPTQo="
  ]
}
EOF

sed 's/"base": "cgr.dev\/chainguard\/wolfi-base"/"base": "alpine"/' \
  "$tmp/out-targets-good" > "$tmp/out-targets-alpine"

sed 's/"base": "cgr.dev\/chainguard\/wolfi-base"/"base": "scratch"/' \
  "$tmp/out-targets-good" > "$tmp/out-targets-scratch"

# A base value carrying a JSON escape (as buildx would print for a base
# containing a quote); the script must refuse to decode it.
cat > "$tmp/out-targets-escape" <<'EOF'
#1 [internal] load build definition from Dockerfile
#1 DONE 0.0s
{
  "targets": [
    {
      "default": true,
      "base": "alp\"ine",
      "location": {}
    }
  ],
  "sources": [
    "RlJPTQo="
  ]
}
EOF

# A named builder stage plus an unnamed default stage based on it; the
# pairing of each "name" with the following "base" and the alias
# classification of the second base both matter here.
cat > "$tmp/out-targets-multi" <<'EOF'
#1 [internal] load build definition from Dockerfile
#1 DONE 0.0s
{
  "targets": [
    {
      "name": "builder",
      "base": "cgr.dev/chainguard/wolfi-base",
      "location": {}
    },
    {
      "default": true,
      "base": "builder",
      "location": {}
    }
  ],
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
shim_case "empty outline output" "$tmp/out-empty" 0 1 "no evidence"
shim_case "unrelated outline output" "$tmp/out-unrelated" 0 1 "no evidence"
# The [linux/amd64 internal] label must parse like any other; the load is
# not in the FROM set, so it is an artifact source, printed and allowed.
shim_case "bracketed-label load is classified as an artifact source" "$tmp/out-mixed" 0 0 \
  "external artifact source docker.io/library/alpine:latest"
shim_case "allowed reference passes" "$tmp/out-good" 0 0 \
  "allowed  cgr.dev/chainguard/wolfi-base:latest"
shim_case "missing load-build-definition step fails" "$tmp/out-nodef" 0 1 "no evidence"
shim_case "missing outline JSON result fails" "$tmp/out-nojson" 0 1 "no evidence"
shim_case "unparsable reference line fails naming it" "$tmp/out-unparsable" 0 1 \
  "load metadata for two tokens"
shim_case "nonzero docker exit fails" "$tmp/out-good" 3 1 "outline run failed (exit 3)"
# An off-allowlist base in the stage graph is rejected in canonical form
# before the outline ever runs.
sc_targets="$tmp/out-targets-alpine"
shim_case "off-allowlist stage in the targets output is rejected" "$tmp/out-good" 0 1 \
  "REJECTED docker.io/library/alpine:latest"
sc_targets="$tmp/out-targets-scratch"
shim_case "scratch-only stage graph with evidence passes" "$tmp/out-scratch" 0 0 \
  "resolve no external base images"
sc_targets="$tmp/out-targets-multi"
shim_case "a base naming an earlier stage is an alias, not a pull" "$tmp/out-good" 0 0 \
  "allowed  cgr.dev/chainguard/wolfi-base:latest"
sc_targets="$tmp/out-targets-escape"
shim_case "JSON escape in a base fails closed" "$tmp/out-good" 0 1 "JSON escape"
sc_targets="$tmp/out-unrelated"
shim_case "targets output without evidence fails" "$tmp/out-good" 0 1 "no evidence"
sc_targets=""
sc_targets_rc=3
shim_case "nonzero targets exit fails" "$tmp/out-good" 0 1 "targets run failed (exit 3)"
sc_targets_rc=""

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

echo "--- case 8: a base identical to its own stage name is a pull, not a stage reference ---"
cat > "$tmp/Dockerfile" <<'EOF'
FROM alpine AS alpine
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "self-named stage: FROM alpine AS alpine pulls alpine and must be rejected, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine"*) ok ;;
    *) bad "self-named stage: should reject alpine, got: $out" ;;
  esac
fi
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/static:latest AS alpine
FROM alpine
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "a base naming a sibling stage is a stage reference and must pass, got exit $rc: $out"; fi

echo ""
echo "test-check-from-oracle: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
