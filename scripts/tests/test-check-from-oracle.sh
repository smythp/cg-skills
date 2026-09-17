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
#      textual parser reads them, because it asks BuildKit itself. A
#      declared default on an automatic argument name is applied with
#      BuildKit's precedence, so the reviewer's single-quoted TARGETVARIANT
#      file is rejected on the alpine base the real build pulls while the
#      benign declared default passes, and a pinned syntax directive runs
#      under its own frontend with one warning, passing for 1.6 and failing
#      as not-a-pass for 1.0, whose frontend cannot answer subrequests.
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
#      printed as external artifact sources and allowed, a reference
#      that is both a base and a copy source is rejected as a base, and a
#      from= source written through the quotes BuildKit drops (a quoted
#      from= field, a quoted target holding a space before the from= key)
#      is still found, so both quoted-mount files pass
#   9. a named context matching a stage's AS name replaces that stage's
#      base at the definition, so the substituted reference is what meets
#      the allowlist, with reference normalization on the context name
#  10. context names keep their registry host case and compare byte-exact,
#      so an uppercase-host spelling matches nothing
#  11. a VT-prefixed escape directive is honored by the scan as BuildKit
#      honors it, so the continuation it enables cannot split the scan
#      from the frontend
#  12. a forward stage reference is a stage reference, not a pull; the
#      FROM set holds only the later stage's base
#
# The shim cases need no container engine: a docker shim on PATH prints
# canned output per call (targets and outline separately, and a timeout
# shim shortens the bound), pinning the exit
# status for empty output, unrelated output, a bracketed-label load that
# must classify as an artifact source, an off-set load in a file with no
# artifact-capable instruction, which is an unexpanded base and fails, an
# unparsable reference line, a
# scratch-only stage graph, an off-allowlist stage, an alias base, a JSON
# escape in a base, targets runs that fail or lack evidence, outline runs
# missing either evidence marker, a nonzero
# docker exit, a timed-out run (asserting the timeout status 124, skipped
# with a reason when no timer is installed), the BUILD* and TARGET*
# overrides asserted pair by pair on both captured buildx invocations, a
# declared automatic default whose synthetic override must be omitted from
# both invocations while the other packs still travel, a
# [context NAME] load line matched against the FROM set, a configured
# source policy, a pinned
# syntax directive that runs both calls with one warning, a context
# directory named --help, whose name must reach docker as a path after --,
# never as an option, a base written as artifact-capable rejected as a
# FROM-set member, copy and mount sources naming a stage left out of the
# artifact-capable count while an image source stays in it, plus-signed
# stage indices left out of the count while a negative index stays in it,
# a quoted mount without from= counting nothing while an unterminated
# quote swallows the line and its from= counts, a base expanding to
# whitespace or to nothing refused by name before serialization, and the
# single-quoted default rejected from the FROM set with no outline
# invocation on the args log.

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

echo "--- case 1d: declared default for an automatic argument is applied ---"
# The pull-request reproduction. The real build keeps the single-quoted
# default literal, so TARGETVARIANT is set and non-empty, BASE becomes
# alpine, and alpine is pulled on every platform (re-pinned with real
# cacheonly builds on 2026-09-17). The pack builder omits the synthetic
# TARGETVARIANT override for the declared default and the scan applies the
# same precedence, so the FROM set holds alpine and the run rejects it
# under both platforms, exactly what the real build pulls. A synthetic
# override here would have emptied TARGETVARIANT and passed wolfi-base, the
# reverse of the build.
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
      *"REJECTED docker.io/library/alpine"*) ok ;;
      *) bad "declared automatic default ($plat): should reject alpine, the base the real build pulls, got: $out" ;;
    esac
  fi
done

echo "--- case 1d2: benign declared default for an automatic argument passes ---"
# The benign shape of the same construct: the declared default is applied
# with BuildKit's precedence (a real cacheonly build of this file resolves
# only wolfi-base, 2026-09-17), nothing resolves off the allowlist, and
# the run passes.
cat > "$tmp/Dockerfile" <<'EOF'
ARG TARGETARCH=amd64
FROM cgr.dev/chainguard/wolfi-base
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "benign declared default: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/wolfi-base"*) ok ;;
    *) bad "benign declared default: should allow wolfi-base, got: $out" ;;
  esac
fi

echo "--- case 1e: single-quoted ARG default stays literal in the scan ---"
# BuildKit keeps the single-quoted default literal, so X is set and
# non-empty, B becomes the alpine reference, and the outline of this file
# resolves docker.io/library/alpine:latest (pinned by an outline run). The
# scan keeps the same literal, so alpine enters the FROM set and the
# FROM-set check rejects it by name before the outline runs; a scan that
# expanded inside the single quotes would empty X, resolve wolfi-base, and
# reach the outline, whose unexpanded-base fallback prints the same
# REJECTED alpine line. The FROM-set summary tells the two paths apart:
# only the FROM-set check prints it, so it is asserted here, and the shim
# companion below asserts on the args log that the outline call never
# reaches docker. The artifact assertion pins that the rejection is not an
# artifact classification of the alpine load.
cat > "$tmp/Dockerfile" <<'EOF'
ARG X='${UNSET}'
ARG B=${X:+docker.io/library/alpine}
FROM ${B:-cgr.dev/chainguard/wolfi-base}
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "single-quoted literal default: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "single-quoted literal default: the FROM-set check should reject alpine by name, got: $out" ;;
  esac
  case "$out" in
    *"the file's FROM set contains at least one base image off the allowlist"*) ok ;;
    *) bad "single-quoted literal default: the rejection must carry the FROM-set summary, not the fallback text, got: $out" ;;
  esac
  case "$out" in
    *"external artifact source"*) bad "single-quoted literal default: alpine must be a rejected base, not an artifact source, got: $out" ;;
    *) ok ;;
  esac
fi

echo "--- case 1f: a pinned frontend that answers the calls passes with the warning ---"
# docker/dockerfile:1.6 answers both subrequest calls itself (verified
# 2026-09-17: the progress log resolves only the 1.6 frontend image), so
# BuildKit resolves the file under the pin and the run passes, with one
# WARNING that the textual expansion assumes the rolling syntax.
cat > "$tmp/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1.6
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "pinned 1.6: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: the syntax directive pins the frontend docker/dockerfile:1.6"*)
      case "$out" in
        *"allowed  cgr.dev/chainguard/wolfi-base"*) ok ;;
        *) bad "pinned 1.6: should allow wolfi-base, got: $out" ;;
      esac
      ;;
    *) bad "pinned 1.6: should print the pinned-frontend warning, got: $out" ;;
  esac
fi

echo "--- case 1g: a pinned frontend without subrequest support is not a pass ---"
# docker/dockerfile:1.0 fails both calls with unsupported frontend
# capability moby.buildkit.frontend.subrequests (verified 2026-09-17), so
# the run is not a pass and the message names the pin and the way out.
cat > "$tmp/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1.0
FROM cgr.dev/chainguard/wolfi-base
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "pinned 1.0: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"the pinned frontend docker/dockerfile:1.0 does not support the outline call"*)
      case "$out" in
        *"switching the directive to docker/dockerfile:1 lets the gate run"*) ok ;;
        *) bad "pinned 1.0: should name the way out, got: $out" ;;
      esac
      ;;
    *) bad "pinned 1.0: should say the frontend lacks the outline call, got: $out" ;;
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
# exist, so the run fails naming it. The assertion requires b-arm64 on an
# indented "  | " line, which only the relayed buildx output carries, so
# the FROM-set messages the script prints first (which also spell b-arm64)
# cannot satisfy it; a frontend resolving the daemon's own architecture
# would fail on b-amd64 instead and the case would catch it. The shim case
# below asserts the same overrides on the captured buildx argument list.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base:b-${BUILDARCH}
EOF
out=$(sh "$SCRIPT" --platform linux/amd64 --build-platform linux/arm64 "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "build-platform override: expected a failing run, got a pass"
else
  if printf '%s\n' "$out" | grep -q '^  | .*b-arm64'; then
    ok
  else
    bad "build-platform override: the relayed buildx output should name the b-arm64 tag, got: $out"
  fi
fi

echo "--- case 6: named build context override ---"
# The pull-request reproduction. The override makes the Chainguard FROM
# resolve to alpine, and the rejecting mechanism is the FROM-set
# substitution: the scan replaces the base with the context source, alpine
# enters the FROM set, and the FROM-set check rejects it before the
# outline runs, so no [context NAME] progress line is parsed on this
# branch. The same override pointed at another Chainguard image passes,
# and there the outline does print the substituted load under the
# [context NAME] label; the shim case below pins that label parsing with
# canned outline output.
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
    *"WARNING: external artifact source docker.io/library/busybox:latest"*) ok ;;
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
    *"WARNING: external artifact source docker.io/library/alpine:latest"*) ok ;;
    *) bad "mount artifact source: should report alpine as an artifact source, got: $out" ;;
  esac
fi
# BuildKit lowercases mount option keys before matching them (a real
# cacheonly build accepts FROM=, Type=, and From= spellings, and the FROM=
# bind mount serves the image content), so the artifact-capable count must
# read the key case-insensitively. The outline of this file resolves
# alpine; a count that missed the uppercase key would leave it at zero and
# reject the load as an unexpanded base, failing this passing file.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=type=bind,FROM=alpine,target=/mnt echo hi
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "uppercase mount key: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: external artifact source docker.io/library/alpine:latest"*) ok ;;
    *) bad "uppercase mount key: should report alpine as an artifact source, got: $out" ;;
  esac
fi
# BuildKit reads quotes in a mount value before the comma split, each rule
# pinned by a real cacheonly build on this daemon: a single or double quote
# opens a span whose whitespace stays inside the flag word, the quote
# characters are dropped, and the key=value split runs on the unquoted
# text, so the quoted from= field below loads busybox and serves it into
# the mount, and the quoted target holding a space before the from= key
# builds the same way. The scan must find both from= sources; a scan that
# read the first key with its quote attached counted nothing, left the
# count at zero, and rejected the busybox load as an unexpanded base,
# failing two files BuildKit accepts.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=type=bind,"from=docker.io/library/busybox:latest",target=/mnt ls /mnt
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "quoted mount from: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: external artifact source docker.io/library/busybox:latest"*) ok ;;
    *) bad "quoted mount from: should report busybox as an artifact source, got: $out" ;;
  esac
fi
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=type=bind,"target=/m nt",from=docker.io/library/busybox:latest ls "/m nt"
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "quoted mount target with space: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: external artifact source docker.io/library/busybox:latest"*) ok ;;
    *) bad "quoted mount target with space: should report busybox as an artifact source, got: $out" ;;
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
# not in the FROM set and the file carries a COPY --from, so it is an
# artifact source, printed and allowed. The same outline output against a
# file with no artifact-capable instruction is the unexpanded-base pair
# below: the off-set load can only be a base the scan missed, so the run
# fails naming it instead of reporting an artifact.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY --from=alpine /etc/os-release /o
EOF
shim_case "bracketed-label load is classified as an artifact source" "$tmp/out-mixed" 0 0 \
  "WARNING: external artifact source docker.io/library/alpine:latest"
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF
shim_case "off-set load with no artifact-capable instruction is an unexpanded base" "$tmp/out-mixed" 0 1 \
  "unexpanded base"
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

echo "--- shim case: the platform and target overrides reach both buildx calls ---"
# Case 5's mechanism, asserted on the captured argument list: whatever the
# script prints before the buildx calls, the frontend sees only what is on
# the invocation, so every TARGET* and BUILD* override must appear as a
# --build-arg pair on the targets call and again on the outline call, with
# the values the normalization rules produce for the platforms passed here
# (x86_64 becomes amd64 and drops the v1 variant, aarch64 becomes arm64
# and drops the 8 variant). TARGETSTAGE travels as the --target flag,
# which BuildKit sets it from, so the flag and its stage name are asserted
# on both calls the same way. The args log holds one argument per line for
# every invocation; the awk below cuts the section between one --call
# value and the next invocation's leading buildx, and each assertion
# requires the value on the line directly after its flag.
bplog="$tmp/bplog"
: > "$bplog"
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-good" SHIM_ARGS="$bplog" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" --platform linux/x86_64/v1 --build-platform linux/aarch64/8 \
      --target final "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "platform overrides: expected pass, exit $rc: $out"
else
  ok
fi
for call in targets outline; do
  callargs=$(awk -v want="--call=$call,format=json" '
    $0 == "buildx" { insec = 0 }
    insec { print }
    $0 == want { insec = 1 }
  ' "$bplog")
  if [ -n "$callargs" ]; then ok; else bad "platform overrides: no $call call reached docker"; fi
  for want in TARGETPLATFORM=linux/amd64 TARGETOS=linux TARGETARCH=amd64 \
              TARGETVARIANT= TARGETOSVERSION= BUILDPLATFORM=linux/arm64 \
              BUILDOS=linux BUILDARCH=arm64 BUILDVARIANT= BUILDOSVERSION=; do
    if printf '%s\n' "$callargs" | awk -v v="$want" \
         'prev == "--build-arg" && $0 == v { found = 1 } { prev = $0 } END { exit !found }'; then
      ok
    else
      bad "platform overrides: the $call call did not receive --build-arg $want; it got: $(printf '%s' "$callargs" | tr '\n' ' ')"
    fi
  done
  if printf '%s\n' "$callargs" | awk \
       'prev == "--target" && $0 == "final" { found = 1 } { prev = $0 } END { exit !found }'; then
    ok
  else
    bad "platform overrides: the $call call did not receive --target final; it got: $(printf '%s' "$callargs" | tr '\n' ' ')"
  fi
done

echo "--- shim case: a [context NAME] load line reaching the outline is matched as a base ---"
# An outline whose only load carries the [context NAME] label, shaped as a
# real run prints it for an overridden base. The same context substitutes
# the reference into the FROM set, so the labeled load must parse and
# match the set, not fail as unparsable and not report as an artifact.
cat > "$tmp/out-ctxlabel" <<'EOF'
#0 building with "default" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 84B done
#1 DONE 0.0s

#2 [context cgr.dev/chainguard/wolfi-base] load metadata for cgr.dev/chainguard/static:latest
#2 DONE 0.1s
{
  "sources": [
    "RlJPTQo="
  ]
}
EOF
out=$(SHIM_OUT="$tmp/out-ctxlabel" SHIM_OUT_TARGETS="$tmp/out-targets-good" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" \
      --build-context cgr.dev/chainguard/wolfi-base=docker-image://cgr.dev/chainguard/static:latest \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "context-label load: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/static:latest"*)
      case "$out" in
        *"external artifact source"*) bad "context-label load: the substituted load must match the FROM set, not report as an artifact, got: $out" ;;
        *) ok ;;
      esac
      ;;
    *) bad "context-label load: should allow the substituted static base, got: $out" ;;
  esac
fi

echo "--- shim case: timed-out run ---"
# Requires a real timer: the assertion is the timeout exit status 124 from
# the bounded targets call, not a generic failure. Without one the shim
# runs the command unbounded, the case would wait out the shim sleep and
# fail on the empty output instead, which proves nothing about the bound,
# so it is skipped with the reason printed.
if [ -z "$real_timeout" ]; then
  echo "SKIP: timed-out run (neither timeout nor gtimeout is installed, so the bound cannot fire and the timeout status cannot be observed)"
else
  out=$(SHIM_SLEEP=10 PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "timed-out run: expected exit 1, got $rc: $out"
  else
    case "$out" in
      *"targets run failed (exit 124)"*) ok ;;
      *) bad "timed-out run: should carry the timeout status 124 from the bounded targets call, got: $out" ;;
    esac
  fi
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

echo "--- shim case: a pinned syntax directive runs both calls with one warning ---"
# The pinned frontend runs and BuildKit decides; the scan only warns that
# its textual expansion assumes the rolling syntax. With the shim answering
# both calls the run passes, the warning names the pin, and the args log
# shows both calls reached docker.
cat > "$tmp/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1.6
FROM cgr.dev/chainguard/wolfi-base
EOF
synlog="$tmp/synlog"
: > "$synlog"
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-good" SHIM_ARGS="$synlog" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "pinned syntax runs: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: the syntax directive pins the frontend docker/dockerfile:1.6"*) ok ;;
    *) bad "pinned syntax runs: should print the pinned-frontend warning, got: $out" ;;
  esac
fi
if grep -qx -- '--call=targets,format=json' "$synlog" && grep -qx -- '--call=outline,format=json' "$synlog"; then
  ok
else
  bad "pinned syntax runs: both calls should reach docker, got: $(cat "$synlog")"
fi
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

echo "--- shim case: a declared automatic default omits its synthetic override ---"
# The pack builder passes a synthetic override for each automatic name so
# the platform reaches the frontend, except a name the file gives a
# declared global default, which BuildKit lets beat an automatic value
# while a --build-arg would beat the default; for that name nothing is
# passed and the frontend applies the declared default, as the real build
# does. Asserted on the captured argument list of both calls: no TARGETARCH
# pack at all, while TARGETOS still travels.
cat > "$tmp/Dockerfile" <<'EOF'
ARG TARGETARCH=amd64
FROM cgr.dev/chainguard/wolfi-base
EOF
dalog="$tmp/dalog"
: > "$dalog"
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-good" SHIM_ARGS="$dalog" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" --platform linux/aarch64 \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "declared-default pack omission: expected pass, exit $rc: $out"
else
  ok
fi
for call in targets outline; do
  callargs=$(awk -v want="--call=$call,format=json" '
    $0 == "buildx" { insec = 0 }
    insec { print }
    $0 == want { insec = 1 }
  ' "$dalog")
  if printf '%s\n' "$callargs" | grep -q '^TARGETARCH='; then
    bad "declared-default pack omission: the $call call carries a TARGETARCH override although the file declares a default; it got: $(printf '%s' "$callargs" | tr '\n' ' ')"
  else
    ok
  fi
  if printf '%s\n' "$callargs" | awk \
       'prev == "--build-arg" && $0 == "TARGETOS=linux" { found = 1 } { prev = $0 } END { exit !found }'; then
    ok
  else
    bad "declared-default pack omission: the $call call should still receive --build-arg TARGETOS=linux; it got: $(printf '%s' "$callargs" | tr '\n' ' ')"
  fi
done
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

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

echo "--- shim case: a base written as artifact-capable is a member, not the count ---"
# The count line the scan hands the reader begins with a TAB, which no
# reference can, so a base spelled exactly artifact-capable stays a
# FROM-set member and meets the allowlist like any other. Before the TAB
# sentinel it matched the count line's literal prefix: the member skipped
# the allowlist, the reference overwrote the count, test(1) printed an
# Illegal number error, and the run exited 0 with the base laundered as an
# artifact source.
cat > "$tmp/Dockerfile" <<'EOF'
FROM artifact-capable
EOF
sed 's/"base": "cgr.dev\/chainguard\/wolfi-base"/"base": "artifact-capable"/' \
  "$tmp/out-targets-good" > "$tmp/out-targets-artcap"
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-artcap" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "artifact-capable base: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"REJECTED docker.io/library/artifact-capable:latest"*) ok ;;
    *) bad "artifact-capable base: should reject it in canonical form, got: $out" ;;
  esac
  case "$out" in
    *"Illegal number"*) bad "artifact-capable base: the count reader read the member as the count: $out" ;;
    *) ok ;;
  esac
fi

echo "--- shim case: a copy or mount source naming a stage is not artifact-capable ---"
# A stage cannot pull an image, so a --from or mount from source naming a
# declared stage leaves the count at zero and the canned off-set alpine
# load is an unexpanded base, exit 1; before the stage exclusion the same
# files counted the stage reference, and the load passed as an artifact
# source. The spellings cover the COPY flag, the case-insensitive stage
# name, the numeric stage index, the plus-signed index BuildKit reads with
# strconv.Atoi (a real cacheonly build copies from stage 0 with --from=+0),
# the mount key, the uppercase mount key BuildKit lowercases before
# matching, and a double-quoted from= field whose quotes the flag parsing
# drops.
for src_line in 'COPY --from=builder /etc/os-release /o' \
                'COPY --from=BUILDER /etc/os-release /o' \
                'COPY --from=0 /etc/os-release /o' \
                'COPY --from=+0 /etc/os-release /o' \
                'COPY --from=+1 /etc/os-release /o' \
                'RUN --mount=type=bind,from=builder,target=/mnt echo hi' \
                'RUN --mount=type=bind,FROM=builder,target=/mnt echo hi' \
                'RUN --mount=type=bind,"from=builder",target=/mnt echo hi'; do
  cat > "$tmp/Dockerfile" <<EOF
FROM cgr.dev/chainguard/wolfi-base AS builder
FROM builder
$src_line
EOF
  out=$(SHIM_OUT="$tmp/out-mixed" SHIM_OUT_TARGETS="$tmp/out-targets-multi" \
        PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "stage source ($src_line): expected exit 1, got $rc: $out"
  else
    case "$out" in
      *"unexpanded base"*) ok ;;
      *) bad "stage source ($src_line): the off-set load should be an unexpanded base, got: $out" ;;
    esac
  fi
done
# The stage match applies after the same ARG expansion the FROM set uses:
# a global ARG naming the stage resolves to it, so the count stays zero.
cat > "$tmp/Dockerfile" <<'EOF'
ARG HELPER=builder
FROM cgr.dev/chainguard/wolfi-base AS builder
FROM builder
COPY --from=${HELPER} /etc/os-release /o
EOF
out=$(SHIM_OUT="$tmp/out-mixed" SHIM_OUT_TARGETS="$tmp/out-targets-multi" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "expanded stage source: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"unexpanded base"*) ok ;;
    *) bad "expanded stage source: the off-set load should be an unexpanded base, got: $out" ;;
  esac
fi
# The same file copying from an image reference keeps the count above
# zero, so its off-set load stays on the artifact-report path.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
FROM builder
COPY --from=busybox:latest /bin/busybox /b
EOF
sed 's/^#2 DONE.*/#3 [linux\/amd64 internal] load metadata for docker.io\/library\/busybox:latest/' \
  "$tmp/out-good" > "$tmp/out-mixed-busybox"
out=$(SHIM_OUT="$tmp/out-mixed-busybox" SHIM_OUT_TARGETS="$tmp/out-targets-multi" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "image copy source: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: external artifact source docker.io/library/busybox:latest"*) ok ;;
    *) bad "image copy source: should report busybox as an artifact source, got: $out" ;;
  esac
fi
# A negative index is never a stage to BuildKit (a real build fails naming
# invalid stage index -1), so it keeps counting and the off-set load stays
# on the artifact-report path.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
FROM builder
COPY --from=-1 /etc/os-release /o
EOF
out=$(SHIM_OUT="$tmp/out-mixed" SHIM_OUT_TARGETS="$tmp/out-targets-multi" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "negative index source: expected pass, exit $rc: $out"
else
  case "$out" in
    *"WARNING: external artifact source docker.io/library/alpine:latest"*) ok ;;
    *) bad "negative index source: the off-set load should stay an artifact source, got: $out" ;;
  esac
fi

echo "--- shim cases: quoted mounts and the artifact-capable count ---"
# The quote rules from the live quoted-mount cases, held against the count
# with a canned off-set load: a quoted mount without a from= key counts
# nothing, so the load is an unexpanded base and the run fails, and an
# unterminated quote swallows the rest of the line into the mount value as
# BuildKit swallows it (a real cacheonly build accepts the file and honors
# the swallowed from=), so its from= source counts and the load stays an
# artifact source.
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=type=cache,"target=/my cache" echo hi
EOF
shim_case "a quoted mount without from= counts nothing" "$tmp/out-mixed" 0 1 "unexpanded base"
cat > "$tmp/Dockerfile" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=type=bind,"from=docker.io/library/busybox:latest,target=/mnt echo hi
EOF
shim_case "an unterminated quote swallows the line and its from= counts" "$tmp/out-mixed" 0 0 \
  "WARNING: external artifact source docker.io/library/alpine:latest"

echo "--- shim case: a base expanding to whitespace or empty is rejected by name ---"
# The FROM-set scan refuses to serialize a member whose expanded form is
# empty or contains whitespace, naming the base and the stage, before the
# allowlist or the count reader can meet the malformed line. A TAB
# smuggled through --build-arg into the base must hit that refusal, not
# the numeric backstop on the count line, and the outline call must never
# run; an empty expansion is refused the same way (a real build fails
# with base name should not be blank).
cat > "$tmp/Dockerfile" <<'EOF'
ARG SNEAK
FROM ${SNEAK}
EOF
sed 's/"base": "cgr.dev\/chainguard\/wolfi-base"/"base": "${SNEAK}"/' \
  "$tmp/out-targets-good" > "$tmp/out-targets-sneak"
sneaklog="$tmp/sneaklog"
: > "$sneaklog"
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-sneak" SHIM_ARGS="$sneaklog" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" \
      --build-arg "SNEAK=$(printf 'cgr.dev/x\tartifact-capable\t9')" \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "tab-smuggled base: expected exit 1, got $rc: $out"
else
  case "$out" in
    *'the base "${SNEAK}" of stage 1 expands to a reference containing whitespace'*) ok ;;
    *) bad "tab-smuggled base: should name the base and the stage in the whitespace refusal, got: $out" ;;
  esac
  case "$out" in
    *"no numeric artifact-capable count"*) bad "tab-smuggled base: the refusal should come from the scan, not the count reader backstop, got: $out" ;;
    *) ok ;;
  esac
fi
if grep -qx -- '--call=outline,format=json' "$sneaklog"; then
  bad "tab-smuggled base: the outline call reached docker although the FROM set already failed: $(cat "$sneaklog")"
else
  ok
fi
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-sneak" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" --build-arg "SNEAK=" \
      "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "empty-expanding base: expected exit 1, got $rc: $out"
else
  case "$out" in
    *'the base "${SNEAK}" of stage 1 expands to an empty reference'*) ok ;;
    *) bad "empty-expanding base: should name the base and the stage in the empty refusal, got: $out" ;;
  esac
fi

echo "--- shim case: the single-quoted default rejects from the FROM set with no outline call ---"
# Case 1e's discriminating half. With the base as written in the canned
# targets output, the scan must keep the single-quoted default literal,
# reject alpine from the FROM set, and never reach the outline; a scan
# that expanded inside the single quotes would pass the FROM set and
# invoke the outline call. The args log shows every docker invocation, so
# it must hold the targets call and no outline call.
cat > "$tmp/Dockerfile" <<'EOF'
ARG X='${UNSET}'
ARG B=${X:+docker.io/library/alpine}
FROM ${B:-cgr.dev/chainguard/wolfi-base}
EOF
cat > "$tmp/out-targets-quoted" <<'EOF'
#1 [internal] load build definition from Dockerfile
#1 DONE 0.0s
{
  "targets": [
    {
      "default": true,
      "base": "${B:-cgr.dev/chainguard/wolfi-base}",
      "location": {}
    }
  ],
  "sources": [
    "RlJPTQo="
  ]
}
EOF
quotedlog="$tmp/quotedlog"
: > "$quotedlog"
out=$(SHIM_OUT="$tmp/out-good" SHIM_OUT_TARGETS="$tmp/out-targets-quoted" SHIM_ARGS="$quotedlog" \
      PATH="$shimdir:$PATH" sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 1 ]; then
  bad "quoted-default shim: expected exit 1, got $rc: $out"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine:latest"*) ok ;;
    *) bad "quoted-default shim: should reject alpine by name, got: $out" ;;
  esac
  case "$out" in
    *"the file's FROM set contains at least one base image off the allowlist"*) ok ;;
    *) bad "quoted-default shim: should print the FROM-set failure summary, got: $out" ;;
  esac
fi
if grep -qx -- '--call=targets,format=json' "$quotedlog"; then
  ok
else
  bad "quoted-default shim: the targets call never reached docker: $(cat "$quotedlog")"
fi
if grep -qx -- '--call=outline,format=json' "$quotedlog"; then
  bad "quoted-default shim: the outline call reached docker although the FROM set already failed: $(cat "$quotedlog")"
else
  ok
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

echo "--- case 11: VT-prefixed escape directive reaches the scan ---"
# The review reproduction, built with printf because the deciding VT byte
# would be invisible here. BuildKit treats VT as whitespace inside a
# directive line, so the escape directive is honored, the backtick
# continues the first ARG line and swallows the FROM ignored text, the
# second ARG reassigns A, and the build resolves docker.io/library/alpine
# (pinned by an outline run of this exact file). A scan that missed the
# directive kept A at the Chainguard value, passed the FROM set, and
# reported the alpine load as an artifact source. The scan now normalizes
# VT and FF in directive lines as check-from-lines.sh does, resolves
# alpine into the FROM set, and rejects it.
printf '#\013escape=`\nARG A=cgr.dev/chainguard/static `\nFROM ignored\nARG A=docker.io/library/alpine\nFROM $A\n' > "$tmp/Dockerfile"
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  bad "VT-prefixed escape directive: expected rejection, got a pass"
else
  case "$out" in
    *"REJECTED docker.io/library/alpine"*) ok ;;
    *) bad "VT-prefixed escape directive: should reject alpine from the FROM set, got: $out" ;;
  esac
fi

echo "--- case 12: a forward stage reference is a stage reference, not a pull ---"
# Pinned by this very run: the outline loads only the later stage's base,
# cgr.dev/chainguard/wolfi-base, so a base naming a stage declared after
# its referencing stage resolves to that stage. The targets JSON lists the
# named stage after the stage whose base references it, and the FROM set
# must hold only wolfi-base; a set that treated helper as a pull would
# reject it and fail this case.
cat > "$tmp/Dockerfile" <<'EOF'
FROM helper
FROM cgr.dev/chainguard/wolfi-base AS helper
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  bad "forward stage reference: expected pass, exit $rc: $out"
else
  case "$out" in
    *"allowed  cgr.dev/chainguard/wolfi-base:latest"*) ok ;;
    *) bad "forward stage reference: should allow only the wolfi-base base, got: $out" ;;
  esac
fi

echo ""
echo "test-check-from-oracle: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
