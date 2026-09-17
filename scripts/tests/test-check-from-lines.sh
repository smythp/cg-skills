#!/bin/sh
# Fixture tests for check-from-lines.sh, ported from Guardener's FROM
# validation test cases, including every stage-alias case. Run from anywhere: ./test-check-from-lines.sh
#
# The heredoc, parser-directive, continuation, and ARG-expansion fixtures
# were each checked against BuildKit before their expected result was
# written: docker buildx build --call=outline -f FIXTURE . prints, in its
# progress log, a "load metadata for IMAGE" line for every stage base the
# builder resolves, and parse errors surface directly (Docker 29.8, builtin
# Dockerfile frontend). The oracle's answer is recorded above each such
# fixture.
#
# Dependencies: sh, awk. No network, no Docker.

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-from-lines.sh"
tmp="$(mktemp -d)" || exit 1
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
failcount=0

# run_case NAME MIRROR EXPECT CONTAINS [ARG...]  (dockerfile on stdin)
#   EXPECT: ok   -> script must exit 0
#           err  -> script must exit non-zero and output must contain CONTAINS
#           warn -> script must exit 3 and output must contain UNVERIFIED
#                   and CONTAINS (an advisory construct, decided by the
#                   oracle)
#   An extra argument of --platform, --build-platform, --target, or
#   --build-context passes
#   through with its following value; every other extra argument is passed
#   as --build-arg NAME=value.
run_case() {
  name="$1"; mirror="$2"; expect="$3"; contains="$4"; shift 4
  cat > "$tmp/Dockerfile"
  # Fixture argument values contain no whitespace, so a string build with
  # unquoted expansion below is safe.
  extra=""
  pend=0
  for a in "$@"; do
    if [ "$pend" -eq 1 ]; then extra="$extra $a"; pend=0; continue; fi
    case "$a" in
      --platform|--build-platform|--target|--build-context) extra="$extra $a"; pend=1 ;;
      *) extra="$extra --build-arg $a" ;;
    esac
  done
  if [ -n "$mirror" ]; then
    out=$(sh "$SCRIPT" --mirror "$mirror" $extra "$tmp/Dockerfile" 2>&1); rc=$?
  else
    out=$(sh "$SCRIPT" $extra "$tmp/Dockerfile" 2>&1); rc=$?
  fi
  if [ "$expect" = "ok" ]; then
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
    else
      failcount=$((failcount + 1))
      echo "FAIL: $name — expected pass, got exit $rc: $out"
    fi
  elif [ "$expect" = "warn" ]; then
    if [ "$rc" -ne 3 ]; then
      failcount=$((failcount + 1))
      echo "FAIL: $name — expected exit 3 (UNVERIFIED), got exit $rc: $out"
    else
      case "$out" in
        *UNVERIFIED*)
          case "$out" in
            *"$contains"*) pass=$((pass + 1)) ;;
            *)
              failcount=$((failcount + 1))
              echo "FAIL: $name — output should contain '$contains', got: $out"
              ;;
          esac
          ;;
        *)
          failcount=$((failcount + 1))
          echo "FAIL: $name — output should contain UNVERIFIED, got: $out"
          ;;
      esac
    fi
  else
    if [ "$rc" -eq 0 ]; then
      failcount=$((failcount + 1))
      echo "FAIL: $name — expected rejection, but it passed"
    else
      case "$out" in
        *"$contains"*) pass=$((pass + 1)) ;;
        *)
          failcount=$((failcount + 1))
          echo "FAIL: $name — error should contain '$contains', got: $out"
          ;;
      esac
    fi
  fi
}

run_case "public cgr.dev/chainguard is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "public cgr.dev via ARG default is allowed" "" ok "" <<'EOF'
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

run_case "public cgr.dev via quoted ARG default is allowed" "" ok "" <<'EOF'
ARG BASE="cgr.dev/chainguard/python:latest-dev"
FROM ${BASE}
RUN echo hi
EOF

run_case "public cgr.dev via single-quoted ARG default is allowed" "" ok "" <<'EOF'
ARG BASE='cgr.dev/chainguard/python:latest-dev'
FROM ${BASE}
RUN echo hi
EOF

run_case "quoted ARG default holding upstream registry is rejected" "" err "docker.io/python:3.12" <<'EOF'
ARG BASE="docker.io/python:3.12"
FROM ${BASE}
RUN echo hi
EOF

run_case "ARG default composed from earlier ARG is allowed" "" ok "" <<'EOF'
ARG REG=cgr.dev/chainguard
ARG BASE=$REG/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

run_case "global ARG default can be reused by a later FROM" "" ok "" <<'EOF'
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM cgr.dev/chainguard/wolfi-base as builder
ARG BASE
FROM ${BASE}
RUN echo hi
EOF

run_case "BuildKit builtin BUILDPLATFORM in --platform flag is allowed" "" ok "" <<'EOF'
FROM --platform=$BUILDPLATFORM cgr.dev/chainguard/go:latest
RUN go build .
EOF

run_case "external mirror via composed ARG default is allowed" "my-corp.example.io/chainguard-remote" ok "" <<'EOF'
ARG REGISTRY=my-corp.example.io/chainguard-remote
FROM ${REGISTRY}/python:latest-dev
RUN echo hi
EOF

run_case "customer-private cgr.dev group UIDP is allowed" "" ok "" <<'EOF'
FROM cgr.dev/0123456789abcdef0123456789abcdef01234567/89abcdef01234567/python:latest-dev
RUN echo hi
EOF

run_case "configured external mirror is allowed" "my-corp.example.io/chainguard-remote" ok "" <<'EOF'
FROM my-corp.example.io/chainguard-remote/python:latest-dev
RUN echo hi
EOF

run_case "configured external mirror with trailing slash is allowed" "my-corp.example.io/chainguard-remote/" ok "" <<'EOF'
FROM my-corp.example.io/chainguard-remote/python:latest-dev
RUN echo hi
EOF

# The mirror prefix travels to awk through the environment. awk -v decodes
# backslash sequences, so a prefix holding a literal backslash-n would turn
# into a newline and stop matching a FROM that spells the same two
# characters. The value below must stay exactly as written on both sides.
run_case "mirror value with a backslash sequence is not decoded" "my\ncorp.example.io/cg" ok "" <<'EOF'
FROM my\ncorp.example.io/cg/python:latest-dev
RUN echo hi
EOF

run_case "configured aws account ecr external mirror is allowed" "123456789012.dkr.ecr.us-west-2.amazonaws.com/chainguard" ok "" <<'EOF'
FROM 123456789012.dkr.ecr.us-west-2.amazonaws.com/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "configured google artifact registry external mirror is allowed" "us-docker.pkg.dev/customer-chainguard/mirror" ok "" <<'EOF'
FROM us-docker.pkg.dev/customer-chainguard/mirror/python:latest-dev
RUN echo hi
EOF

run_case "configured quay external mirror is allowed" "quay.io/customer-chainguard/mirror" ok "" <<'EOF'
FROM quay.io/customer-chainguard/mirror/python:latest-dev
RUN echo hi
EOF

run_case "public wolfi-base final fallback is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

run_case "platform flag with cgr image is allowed" "" ok "" <<'EOF'
ARG TARGETOS
ARG TARGETARCH
FROM --platform=$TARGETOS/$TARGETARCH cgr.dev/chainguard/static:latest
RUN echo hi
EOF

# Oracle: a lone FROM scratch outlines with exit 0 and no "load metadata"
# line; the lowercase spelling is the empty base and pulls nothing.
run_case "scratch is allowed" "" ok "" <<'EOF'
FROM scratch
COPY hello /
EOF

# Oracle: outline fails with failed to parse stage name "SCRATCH": invalid
# reference format: repository name (library/SCRATCH) must be lowercase.
# Only the lowercase spelling is the empty base; any other case is an image
# reference BuildKit refuses, so no base pulls from it and the check
# reports it as UNVERIFIED for the oracle to decide (the oracle fails the
# run on the parse error, which is not a pass).
run_case "FROM SCRATCH is unverified as a reference BuildKit refuses" "" warn "SCRATCH" <<'EOF'
FROM SCRATCH
COPY hello /
EOF

# Oracle: outline fails with failed to parse stage name "alpine:--":
# invalid reference format (2026-09-17); a tag must start with a letter,
# digit, or underscore. No base pulls from a reference BuildKit refuses,
# so the check reports it instead of rejecting a base that never enters
# the build.
run_case "invalid tag is a reference BuildKit refuses, unverified" "" warn "not a reference BuildKit accepts" <<'EOF'
FROM alpine:--
RUN echo hi
EOF

# Oracle: outline fails with failed to parse stage name
# "alpine@sha256:zzz": invalid reference format (2026-09-17); a digest
# needs letter-led algorithm segments, a colon, and at least 32 hex
# digits, so this base pulls nothing and is reported, not rejected.
run_case "malformed digest is a reference BuildKit refuses, unverified" "" warn "not a reference BuildKit accepts" <<'EOF'
FROM alpine@sha256:zzz
RUN echo hi
EOF

# Oracle: outline fails with dockerfile parse error on line 1: FROM requires
# either one or three arguments (three tokens whose middle one is not AS
# draw the same message). No base pulls from such a line, so the check
# reports the token count as UNVERIFIED instead of deciding.
run_case "FROM with two extra tokens is unverified" "" warn "one or three arguments" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base:latest foo bar
EOF

# Oracle: outline fails with dockerfile parse error on line 1: FROM requires
# either one or three arguments; a trailing AS with no stage name is two
# arguments.
run_case "FROM followed by a bare AS is unverified" "" warn "one or three arguments" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base:latest AS
EOF

# Oracle: outline resolves cgr.dev/chainguard/wolfi-base:latest with exit 0;
# the reference plus AS plus a stage name is the allowed three-token form.
run_case "FROM with a reference and an AS name stays allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base:latest AS y
EOF

run_case "stage alias is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS builder
RUN go build .
FROM builder
EOF

run_case "stage alias chain is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/node:latest-dev AS output
FROM output as testenvironment
FROM output
RUN echo hi
EOF

run_case "stage alias with uppercase is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS Builder
RUN go build .
FROM Builder
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base:latest is resolved; BuildKit
# resolves stage names anywhere in the file, so FROM helper is a reference
# to the later stage, not a pull. This check reads the file top to bottom
# and trusts only aliases already declared, so it reports the forward
# reference as UNVERIFIED at the end of the scan, when every stage name is
# known; the oracle resolves it from the stage graph and accepts the file
# (its test case 12).
run_case "forward stage reference is unverified" "" warn "helper" <<'EOF'
FROM helper
FROM cgr.dev/chainguard/wolfi-base AS helper
EOF

run_case "deprecated ghcr.io/chainguard-images mirror is rejected" "" err "ghcr.io/chainguard-images/python:latest-dev" <<'EOF'
FROM ghcr.io/chainguard-images/python:latest-dev
RUN echo hi
EOF

run_case "deprecated ghcr.io via ARG default is rejected" "" err "ghcr.io/chainguard-images/python:latest-dev" <<'EOF'
ARG BASE=ghcr.io/chainguard-images/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

run_case "docker.io explicit upstream image is rejected" "" err "docker.io/golang:1.11" <<'EOF'
FROM docker.io/golang:1.11
RUN echo hi
EOF

run_case "public ecr upstream image is rejected unless configured" "" err "public.ecr.aws/docker/library/alpine:3.19" <<'EOF'
FROM public.ecr.aws/docker/library/alpine:3.19
RUN echo hi
EOF

run_case "aws account ecr chainguard mirror is rejected when not configured" "" err "123456789012.dkr.ecr.us-west-2.amazonaws.com" <<'EOF'
FROM 123456789012.dkr.ecr.us-west-2.amazonaws.com/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "google artifact registry chainguard mirror is rejected" "" err "us-docker.pkg.dev/chainguard/images/python:latest-dev" <<'EOF'
FROM us-docker.pkg.dev/chainguard/images/python:latest-dev
RUN echo hi
EOF

run_case "gcr distroless image is rejected unless configured" "" err "gcr.io/distroless/base-debian12" <<'EOF'
FROM gcr.io/distroless/base-debian12 AS app
RUN echo hi
EOF

run_case "quay chainguard mirror is rejected" "" err "quay.io/chainguard/python:latest-dev" <<'EOF'
FROM quay.io/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "azure registry image is rejected" "" err "mcr.microsoft.com/oss/python/python:3.12" <<'EOF'
FROM mcr.microsoft.com/oss/python/python:3.12
RUN echo hi
EOF

run_case "cgr.dev lookalike domain is rejected" "" err "cgr.dev.evil.example.com" <<'EOF'
FROM cgr.dev.evil.example.com/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "external mirror prefix sibling is rejected" "my-corp.example.io/chainguard-remote" err "my-corp.example.io/chainguard-remote-extra" <<'EOF'
FROM my-corp.example.io/chainguard-remote-extra/python:latest-dev
RUN echo hi
EOF

# A declared ARG with no value expands to the empty string, as BuildKit
# expands it, and here the whole reference empties: a real build of
# FROM ${UNSET} fails with base name (${UNSET}) should not be blank
# (2026-09-17), so no base pulls from it and the check reports the empty
# result.
run_case "FROM that expands to an empty base is unverified" "" warn "expands to an empty base" <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo hi
EOF

# The same empty expansion with no declaration at all: an undeclared
# variable expands to the empty string too (a --build-arg without a
# declaration never applies), and the empty base is refused the same way.
run_case "FROM of an undeclared variable is an empty base, unverified" "" warn "expands to an empty base" <<'EOF'
FROM ${UNSET}
RUN echo hi
EOF

# Oracle: a real cacheonly build of this file resolves
# docker.io/library/alpine:latest (2026-09-17): the undeclared variable
# expands to the empty string and the literal that remains is the base.
# The check expands the same way, so the alpine the build really pulls is
# rejected rather than reported as unresolvable.
run_case "undeclared variable suffix leaves alpine and is rejected" "" err "alpine" <<'EOF'
FROM alpine${UNSET}
RUN echo hi
EOF

run_case "stage ARG cannot override global ARG used by later FROM" "" err "ubuntu:22.04" <<'EOF'
ARG BASE=ubuntu:22.04
FROM cgr.dev/chainguard/wolfi-base
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

# A stage ARG never reaches FROM resolution, so the global value is empty
# and the reference expands to an empty base, which BuildKit refuses.
run_case "stage ARG alone cannot satisfy FROM variable" "" warn "expands to an empty base" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

# BuildKit fails such a line with "FROM requires either one or three
# arguments", so no base pulls from it and the check reports it.
run_case "missing base after platform flag is unverified" "" warn "no image reference" <<'EOF'
FROM --platform=linux/amd64
RUN echo hi
EOF

# BuildKit expands the empty default and fails the build (base name should
# not be blank), so no base pulls from it and the check reports it.
run_case "empty ARG base is unverified" "" warn "expands to an empty base" <<'EOF'
ARG BASE=
FROM ${BASE}
RUN echo hi
EOF

run_case "upstream ubuntu is rejected" "" err "ubuntu:22.04" <<'EOF'
FROM ubuntu:22.04
RUN apt-get update
EOF

run_case "upstream debian is rejected" "" err "debian:bookworm" <<'EOF'
FROM debian:bookworm
RUN apt-get update
EOF

run_case "upstream alpine is rejected" "" err "alpine:3.20" <<'EOF'
FROM alpine:3.20
RUN apk add curl
EOF

run_case "docker hub purpose image is rejected" "" err "python:3.12" <<'EOF'
FROM python:3.12
RUN pip install flask
EOF

run_case "private mirror not in configured mirror is rejected" "" err "other-corp.example.io" <<'EOF'
FROM other-corp.example.io/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "multi-stage with one bad FROM rejected" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS builder
RUN go build .
FROM ubuntu:22.04
COPY --from=builder /app /app
EOF

run_case "non-cgr.dev host without mirror is rejected" "" err "images.acme.io/team/go:1.21" <<'EOF'
FROM images.acme.io/team/go:1.21
RUN echo hi
EOF

# Oracle: a real build fails with failed to parse stage name
# "cgr.dev/chainguard/:latest-dev": invalid reference format (2026-09-17).
# The empty expansion leaves a reference BuildKit refuses, and the
# allowlist prefix alone must not vouch for it, because no base pulls
# from a reference the builder refuses.
run_case "empty expansion inside a cgr.dev path is unverified" "" warn "matches the allowlist prefix but is not a reference BuildKit accepts" <<'EOF'
ARG IMG
FROM cgr.dev/chainguard/$IMG:latest-dev
RUN echo hi
EOF

# Oracle: a real build fails with failed to parse stage name
# "/python:latest-dev": invalid reference format (2026-09-17); the empty
# expansion leaves a reference BuildKit refuses.
run_case "empty expansion at the start of a FROM is unverified" "" warn "not a reference BuildKit accepts" <<'EOF'
ARG REG
FROM $REG/python:latest-dev
RUN echo hi
EOF

run_case "mixed-case cgr.dev hostname is allowed" "" ok "" <<'EOF'
FROM CGR.DEV/chainguard/python:latest-dev
RUN echo hi
EOF

run_case "mixed-case external mirror hostname is allowed" "my-corp.example.io/chainguard-remote" ok "" <<'EOF'
FROM My-Corp.Example.io/chainguard-remote/python:latest-dev
RUN echo hi
EOF

# Oracle: docker.io/library/alpine:3.20 is resolved; instruction keywords
# are case-insensitive.
run_case "lowercase from is still a FROM" "" err "alpine:3.20" <<'EOF'
from alpine:3.20
run echo hi
EOF

# Oracle: docker.io/library/alpine:3.20 is resolved; BuildKit strips one
# pair of quotes around a FROM reference. This check does not unquote
# references, so the quoted spelling is a reference it cannot verify and
# it reports the line; the oracle decides (its targets output carries the
# quotes as a JSON escape, which it refuses to decode, so the run is not a
# pass).
run_case "quoted FROM reference is unverified" "" warn "docker.io/library/alpine:3.20" <<'EOF'
FROM "docker.io/library/alpine:3.20"
EOF

# Oracle: cgr.dev/chainguard/wolfi-base:latest@sha256:9a8d954d... is
# resolved as written; a tag plus digest reference passes through the
# allowlist check on its host prefix.
run_case "digest-pinned cgr.dev reference is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:9a8d954d8f03a21bcf2be73d4628f0ad26d35c3275469925de63a34eebd58f13
EOF

run_case "image-shaped alias with slash is rejected" "" err "stage alias" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS docker.io/evil/img
RUN echo hi
EOF

run_case "image-shaped alias with colon is rejected" "" err "stage alias" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS python:latest
RUN echo hi
EOF

run_case "image-shaped alias with at is rejected" "" err "stage alias" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS img@sha256:abc
RUN echo hi
EOF

run_case "alias with dot dash underscore is allowed" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS Build_1.0-stage
FROM Build_1.0-stage
EOF

run_case "alias starting with digit is rejected" "" err "stage alias" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS 1stage
RUN go build .
EOF

run_case "alias starting with hyphen is rejected" "" err "stage alias" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS -builder
RUN go build .
EOF

run_case "alias with shell metacharacter is rejected" "" err "stage alias" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS build!stage
RUN go build .
EOF

run_case "line continuation in FROM is handled" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/go:latest \
  AS builder
FROM builder
EOF

run_case "build-arg override to a forbidden registry is rejected" "" err "docker.io/library/python:3.12" BASE=docker.io/library/python:3.12 <<'EOF'
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

run_case "build-arg override to an allowed registry is accepted" "" ok "" BASE=cgr.dev/chainguard/python:latest-dev <<'EOF'
ARG BASE=docker.io/library/python:3.12
FROM ${BASE}
RUN echo hi
EOF

run_case "build-arg gives a value to a global ARG with no default" "" ok "" BASE=cgr.dev/chainguard/python:latest-dev <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo hi
EOF

run_case "build-arg forbidden value via defaultless ARG is rejected" "" err "ubuntu:22.04" BASE=ubuntu:22.04 <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo hi
EOF

run_case "build-arg with no matching ARG declaration is ignored" "" warn '${BASE}' OTHER=cgr.dev/chainguard/python:latest-dev <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo hi
EOF

# Oracle: docker.io/library/alpine:latest is resolved (real build with
# --platform linux/amd64; buildx 0.37 drops --platform on --call runs, so
# the platform fixtures were verified with real builds, which stop at
# metadata for these files). BuildKit sets TARGETARCH in the global scope on
# every build, so the ARG default expands to alpine and the FROM keeps it.
run_case "automatic TARGETARCH reaches a global ARG default" "" err "alpine" --platform linux/amd64 <<'EOF'
ARG BASE=${TARGETARCH:+alpine}
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
RUN echo hi
EOF

# Oracle: the same file resolves docker.io/library/alpine:latest on every
# platform, because TARGETARCH is always set. Without --platform this check
# does not know the value BuildKit will use, so it reports the read instead
# of answering.
run_case "automatic platform argument without --platform is unverified" "" warn "Pass --platform" <<'EOF'
ARG BASE=${TARGETARCH:+alpine}
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
RUN echo hi
EOF

# Oracle: cgr.dev/chainguard/go:latest-dev is resolved. The variable sits
# inside a FROM flag, which names a manifest platform, not an image, so the
# gate skips it with or without --platform.
run_case "BUILDPLATFORM in a FROM flag needs no --platform" "" ok "" --platform linux/amd64 <<'EOF'
FROM --platform=$BUILDPLATFORM cgr.dev/chainguard/go:latest-dev
RUN go build .
EOF

# Oracle: docker.io/library/alpine:v8 is resolved under --platform
# linux/amd64. TARGETVARIANT is set to the empty string when the platform
# has no variant, and :- treats empty as unset.
run_case "TARGETVARIANT is empty-set on a variantless platform" "" err "alpine:v8" --platform linux/amd64 <<'EOF'
FROM alpine:${TARGETVARIANT:-v8}
EOF

# Oracle: docker.io/library/alpine:v8 is resolved under --platform
# linux/arm64/v8 too: the docker CLI normalizes arm64/v8 to arm64 with no
# variant, so the :- default still applies.
run_case "arm64/v8 normalizes to an empty TARGETVARIANT" "" err "alpine:v8" --platform linux/arm64/v8 <<'EOF'
FROM alpine:${TARGETVARIANT:-v8}
EOF

# Oracle: docker.io/library/alpine:v7 is resolved under --platform
# linux/arm/v7; that variant survives normalization.
run_case "arm/v7 keeps its TARGETVARIANT" "" err "alpine:v7" --platform linux/arm/v7 <<'EOF'
FROM alpine:${TARGETVARIANT:-v8}
EOF

# Oracle: docker.io/library/alpine:q-amd64 is resolved under --platform
# linux/x86_64; the docker CLI normalizes the architecture alias.
run_case "x86_64 normalizes to amd64" "" err "alpine:q-amd64" --platform linux/x86_64 <<'EOF'
FROM alpine:q-${TARGETARCH}
EOF

# The normalization fixtures below pin containerd platforms.Normalize, rule
# by rule. Each expected value comes from a real build of a scratch stage
# labeling the automatic arguments, built with the fixture's --platform and
# inspected (Docker 29.8, buildx 0.37).

# Real build with --platform linux/amd64/v1 seeds TARGETVARIANT empty; the
# v1 variant of amd64 is dropped, so the :- default applies.
run_case "amd64/v1 normalizes to an empty TARGETVARIANT" "" err "alpine:none" --platform linux/amd64/v1 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/amd64/v2 seeds TARGETVARIANT=v2; only v1
# is dropped for amd64.
run_case "amd64/v2 keeps its TARGETVARIANT" "" err "alpine:v2" --platform linux/amd64/v2 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/arm64/8 seeds TARGETVARIANT empty; the
# bare-8 spelling is dropped for arm64 like v8.
run_case "arm64/8 normalizes to an empty TARGETVARIANT" "" err "alpine:none" --platform linux/arm64/8 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/arm seeds TARGETVARIANT=v7.
run_case "bare arm gains the v7 variant" "" err "alpine:v7" --platform linux/arm <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

# Real builds with --platform linux/arm/5, /6, /7, /8 seed TARGETVARIANT
# v5, v6, v7, v8; the numeric arm variants gain the v prefix.
run_case "arm/5 normalizes to the v5 variant" "" err "alpine:v5" --platform linux/arm/5 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

run_case "arm/6 normalizes to the v6 variant" "" err "alpine:v6" --platform linux/arm/6 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

run_case "arm/7 normalizes to the v7 variant" "" err "alpine:v7" --platform linux/arm/7 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

run_case "arm/8 normalizes to the v8 variant" "" err "alpine:v8" --platform linux/arm/8 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/arm/v8 seeds TARGETVARIANT=v8; only
# arm64 drops a v8 variant, arm keeps it.
run_case "arm/v8 keeps its TARGETVARIANT" "" err "alpine:v8" --platform linux/arm/v8 <<'EOF'
FROM alpine:${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/x86-64 seeds TARGETARCH=amd64, the same
# as the x86_64 spelling.
run_case "x86-64 normalizes to amd64" "" err "alpine:q-amd64" --platform linux/x86-64 <<'EOF'
FROM alpine:q-${TARGETARCH}
EOF

# Real build with --platform linux/aarch64 seeds TARGETARCH=arm64 with an
# empty TARGETVARIANT.
run_case "aarch64 normalizes to arm64" "" err "alpine:q-arm64" --platform linux/aarch64 <<'EOF'
FROM alpine:q-${TARGETARCH}
EOF

# Real build with --platform linux/armhf seeds TARGETARCH=arm and
# TARGETVARIANT=v7.
run_case "armhf normalizes to arm/v7" "" err "alpine:arm-v7" --platform linux/armhf <<'EOF'
FROM alpine:${TARGETARCH}-${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/armel seeds TARGETARCH=arm and
# TARGETVARIANT=v6.
run_case "armel normalizes to arm/v6" "" err "alpine:arm-v6" --platform linux/armel <<'EOF'
FROM alpine:${TARGETARCH}-${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/armhf/v6 seeds TARGETVARIANT=v7, not v6;
# armhf replaces any variant it is given.
run_case "armhf with a variant still normalizes to arm/v7" "" err "alpine:arm-v7" --platform linux/armhf/v6 <<'EOF'
FROM alpine:${TARGETARCH}-${TARGETVARIANT:-none}
EOF

# Real build with --platform linux/i386 seeds TARGETARCH=386.
run_case "i386 normalizes to 386" "" err "alpine:q-386" --platform linux/i386 <<'EOF'
FROM alpine:q-${TARGETARCH}
EOF

# Real build with --platform linux/i386/v1 seeds TARGETARCH=386 with an
# empty TARGETVARIANT; i386 drops any variant it is given.
run_case "i386 drops any variant" "" err "alpine:386-none" --platform linux/i386/v1 <<'EOF'
FROM alpine:${TARGETARCH}-${TARGETVARIANT:-none}
EOF

# Oracle: docker.io/library/alpine:3.20 is resolved under --platform
# linux/amd64. A bare global redeclaration keeps the automatic value.
run_case "bare global ARG redeclaration keeps the automatic value" "" err "alpine:3.20" --platform linux/amd64 <<'EOF'
ARG TARGETARCH
FROM ${TARGETARCH:+docker.io/library/alpine:3.20}
EOF

# Oracle: docker.io/library/alpine:arch-riscv64 is resolved under
# --platform linux/amd64 (re-pinned with a real cacheonly build on
# 2026-09-17); the declared default beats the automatic value, unlike a
# bare redeclaration, while a --build-arg beats the default (also
# re-pinned). The check applies the same precedence, so the declared
# default resolves the FROM to the off-allowlist reference.
run_case "declared default for an automatic argument resolves the FROM" "" err "alpine:arch-riscv64" --platform linux/amd64 <<'EOF'
ARG TARGETARCH=riscv64
FROM alpine:arch-${TARGETARCH}
EOF

# The same precedence with an allowed outcome: the declared default is
# applied, nothing reads a value the check does not know, and the file
# passes with or without --platform. The benign shape of the case above.
run_case "benign declared default on an automatic argument passes" "" ok "" <<'EOF'
ARG TARGETARCH=amd64
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

run_case "benign declared default read by the FROM passes" "" ok "" --platform linux/arm64 <<'EOF'
ARG TARGETARCH=amd64
FROM cgr.dev/chainguard/go:tag-${TARGETARCH}
EOF

# Oracle: the real build keeps the single-quoted default literal, so
# TARGETVARIANT holds the seven characters ${UNSET}, BASE becomes alpine
# through the :+ modifier, and docker.io/library/alpine:latest is resolved
# on every platform (re-pinned with real cacheonly builds on 2026-09-17).
# The pull-request reproduction. The check applies the same precedence and
# the same literal quoting, so it resolves alpine and rejects it under
# both platforms.
run_case "declared automatic default with a single-quoted literal resolves alpine (amd64)" "" err "alpine" --platform linux/amd64 <<'EOF'
ARG TARGETVARIANT='${UNSET}'
ARG BASE=${TARGETVARIANT:+alpine}
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
EOF

run_case "declared automatic default with a single-quoted literal resolves alpine (arm64)" "" err "alpine" --platform linux/arm64 <<'EOF'
ARG TARGETVARIANT='${UNSET}'
ARG BASE=${TARGETVARIANT:+alpine}
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base:latest is resolved. BuildKit keeps
# a single-quoted ARG default literal, so X holds the characters ${UNSET},
# it is set and non-empty for the :+ modifier, and B becomes the wolfi-base
# reference. A gate that expanded inside the single quotes would empty X
# and check docker.io/library/alpine instead.
run_case "single-quoted ARG default keeps its variable text literal" "" ok "" <<'EOF'
ARG X='${UNSET}'
ARG B=${X:+cgr.dev/chainguard/wolfi-base}
FROM ${B:-docker.io/library/alpine}
EOF

# Oracle: docker.io/library/alpine:o-xyz is resolved with --build-arg
# TARGETARCH=xyz and no ARG declaration; overrides of automatic arguments
# apply pre-declared, unlike ordinary build args.
run_case "build-arg overrides an automatic argument undeclared" "" err "alpine:o-xyz" --platform linux/amd64 TARGETARCH=xyz <<'EOF'
FROM alpine:o-${TARGETARCH}
EOF

# Oracle: docker.io/library/alpine:b-amd64 is resolved on this amd64 daemon
# under --platform linux/arm64, because docker sets BUILD* to the builder's
# own platform. The gate matches when the caller passes --build-platform.
run_case "BUILDARCH follows --build-platform on a cross build" "" err "alpine:b-amd64" --platform linux/arm64 --build-platform linux/amd64 <<'EOF'
FROM alpine:b-${BUILDARCH}
EOF

# Oracle: the real build on an amd64 daemon resolves alpine:b-amd64 (see
# above). Without --build-platform the gate defaults BUILD* to the target
# platform, so on this cross build it checks alpine:b-arm64 instead; a
# documented deviation, and both spellings are off the allowlist here.
run_case "BUILDARCH defaults to the target platform without --build-platform" "" err "alpine:b-arm64" --platform linux/arm64 <<'EOF'
FROM alpine:b-${BUILDARCH}
EOF

# Oracle: docker.io/library/alpine:s-laststage is resolved with --target
# laststage; TARGETSTAGE carries the target stage name. Without --target,
# BuildKit uses the final stage's name, verified separately.
run_case "TARGETSTAGE carries the --target stage name" "" err "alpine:s-laststage" --platform linux/amd64 --target laststage <<'EOF'
FROM alpine:s-${TARGETSTAGE} AS laststage
EOF

# Oracle: without --target BuildKit sets TARGETSTAGE to the final stage's
# name, which this check cannot know in one streaming pass, so it reports
# the read and asks for --target instead of guessing.
run_case "TARGETSTAGE without --target is unverified" "" warn "Pass --target" --platform linux/amd64 <<'EOF'
FROM alpine:s-${TARGETSTAGE} AS laststage
EOF

# A multi-platform value is a usage error; the caller runs the gate once
# per platform (exit 2, no oracle involved).
run_case "multi-platform value is refused" "" err "one platform per run" --platform linux/amd64,linux/arm64 <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

# --- named build contexts -------------------------------------------------
# Every expected result below was pinned with an outline run on Docker
# 29.8.0 / buildx v0.37.0, whose progress log shows the overridden load as
# "#N [context NAME] load metadata for REF"; the scratch case was pinned
# with a real cacheonly build because the outline resolves nothing there.

# Oracle: with --build-context cgr.dev/chainguard/wolfi-base=
# docker-image://alpine:latest the run loads metadata for alpine:latest
# under the [context] label and never touches wolfi-base. The pull-request
# reproduction: a Chainguard FROM that the build resolves to alpine.
run_case "build context overriding a Chainguard FROM to alpine is rejected" "" err "overridden by --build-context" --build-context cgr.dev/chainguard/wolfi-base=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: the same override pointed at cgr.dev/chainguard/static:latest
# loads static under the [context] label; the substituted reference is on
# the allowlist.
run_case "build context overriding a FROM to another Chainguard image is allowed" "" ok "" --build-context cgr.dev/chainguard/wolfi-base=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: with a local-directory source the outline resolves no metadata at
# all for the overridden name; the base comes from the directory, which has
# no registry reference to verify, so the check reports it and the oracle
# decides the run.
run_case "local-directory context for a FROM name is unverified" "" warn "not a docker-image:// reference" --build-context cgr.dev/chainguard/wolfi-base=./ctxdir <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: a context whose name matches no FROM and no stage changes
# nothing; the run resolves wolfi-base as if the flag were absent.
run_case "context whose name matches nothing is ignored" "" ok "" --build-context zzz=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: a local-directory context for a name only COPY --from uses leaves
# every FROM untouched; artifact sources may come from directories.
run_case "local-directory context for a copy source is ignored by the FROM gate" "" ok "" --build-context assets=./ctxdir <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY --from=assets f /f
EOF

# Oracle: the context name alpine:latest matches FROM alpine; both sides
# normalize to docker.io/library/alpine:latest before the comparison.
run_case "context name with a tag matches an untagged FROM" "" ok "" --build-context alpine:latest=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
EOF

# Oracle: the context name docker.io/library/alpine matches FROM alpine;
# the short name gains docker.io/library/ before the comparison.
run_case "fully qualified context name matches a short FROM" "" ok "" --build-context docker.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
EOF

# Oracle: index.docker.io maps to docker.io in the normalization, so this
# context name also matches FROM alpine.
run_case "index.docker.io context name matches a short FROM" "" ok "" --build-context index.docker.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
EOF

# Oracle: FROM alpine:3.20 loads alpine:3.20 under the [internal] label;
# the context named alpine (normalized tag latest) does not match a
# different tag, so the FROM stays alpine and stays rejected.
run_case "context name with a different tag does not match" "" err "docker.io/library/alpine" --build-context alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM docker.io/library/alpine:3.20
EOF

# Oracle: with --build-context dep=docker-image://alpine:latest the second
# stage loads alpine under [context dep]; a named context beats a stage of
# the same name.
run_case "context overriding a stage alias to alpine is rejected" "" err "overridden by --build-context" --build-context dep=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS dep
FROM dep
EOF

run_case "context overriding a stage alias to a Chainguard image is allowed" "" ok "" --build-context dep=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS dep
FROM dep
EOF

# Oracle: ARG B=alpine, FROM ${B}, and a context named alpine loads the
# context's source; the match happens after variable expansion.
run_case "context matching happens after ARG expansion" "" ok "" --build-context alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
ARG B=alpine
FROM ${B}
EOF

# Real build (cacheonly): FROM scratch with a context named scratch pulls
# nothing and loads no metadata; scratch cannot be overridden by a named
# context, so the empty base stays allowed.
run_case "scratch cannot be overridden by a context" "" ok "" --build-context scratch=docker-image://alpine:latest <<'EOF'
FROM scratch
EOF

# Oracle: a digest reference matches a context only on the exact digest
# string (pinned with wolfi-base's live digest; the fixture digest is
# synthetic, the matching is textual either way).
run_case "context with the exact digest string overrides the FROM" "" err "overridden by --build-context" --build-context cgr.dev/chainguard/wolfi-base@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF

# Oracle: the bare name does not match the digest-pinned FROM (the digest
# FROM loads under [internal] with the context present), so the FROM is
# checked as written and stays allowed.
run_case "bare context name does not match a digest-pinned FROM" "" ok "" --build-context cgr.dev/chainguard/wolfi-base=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF

# Oracle: a repeated context name applies its last value, so the run loads
# the second source.
run_case "repeated context name applies the last value (allowed)" "" ok "" --build-context alpine=docker-image://alpine:latest --build-context alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
EOF

run_case "repeated context name applies the last value (rejected)" "" err "overridden by --build-context" --build-context alpine=docker-image://cgr.dev/chainguard/static:latest --build-context alpine=docker-image://alpine:latest <<'EOF'
FROM alpine
EOF

# buildx itself refuses a context name that is not a valid reference
# (invalid context name DEP, repository name must be lowercase), so the
# captured invocation cannot build with it: a usage error (exit 2).
run_case "invalid context name is refused as a usage error" "" err "not a valid image reference" --build-context DEP=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

# buildx refuses this invocation too (invalid context name dep:--: invalid
# reference format, verified 2026-09-17), because the tag does not start
# with a letter, digit, or underscore.
run_case "context name with an invalid tag is refused as a usage error" "" err "not a valid image reference" --build-context dep:--=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

# Oracle: buildx accepts the flag and the real build then fails with
# invalid reference format (verified 2026-09-17 for docker-image:// with
# an empty reference and with alpine:--), so no base pulls from the
# override and the check reports it, never allowing or rejecting a
# reference the builder refuses.
run_case "empty docker-image context source is unverified" "" warn "not a valid image reference" --build-context cgr.dev/chainguard/wolfi-base=docker-image:// <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

run_case "invalid docker-image context source is unverified" "" warn "not a valid image reference" --build-context cgr.dev/chainguard/wolfi-base=docker-image://alpine:-- <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
EOF

# The same validity rule at a stage definition: the context matches the AS
# name and replaces the base, and its invalid docker-image:// reference is
# reported, not checked against the allowlist.
run_case "invalid docker-image source for a stage name is unverified" "" warn "not a valid image reference" --build-context builder=docker-image://alpine:-- <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo hi
EOF

# Oracle: with --build-context builder=docker-image://alpine:latest the
# outline loads only alpine:latest under [context builder]; wolfi-base is
# never touched. BuildKit applies a context whose name matches a stage's
# AS name at the stage's definition, replacing the stage's base even when
# no FROM references the name.
run_case "stage-name context overriding a Chainguard stage to alpine is rejected" "" err "overridden by --build-context" --build-context builder=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo hi
EOF

# Oracle: the same override pointed at cgr.dev/chainguard/static:latest
# loads only static under [context builder]; the substituted base is on
# the allowlist.
run_case "stage-name context overriding a stage to a Chainguard image is allowed" "" ok "" --build-context builder=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo hi
EOF

# Oracle: the context name docker.io/library/builder also loads alpine
# under [context builder]; reference normalization applies to the name
# before it is matched against the stage name.
run_case "normalized stage-name context still overrides the stage" "" err "overridden by --build-context" --build-context docker.io/library/builder=docker-image://alpine:latest <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo hi
EOF

# Oracle: with --build-context builder=./ctxdir the outline loads no
# metadata at all for the stage; its base comes from the directory, which
# has no registry reference to verify, so the check reports it and the
# oracle decides the run.
run_case "local-directory context for a stage name is unverified" "" warn "not a docker-image:// reference" --build-context builder=./ctxdir <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS builder
RUN echo hi
EOF

# Real build (cacheonly): FROM scratch AS builder with --build-context
# builder=docker-image://alpine:latest resolves docker.io/library/alpine;
# the stage-name match replaces even a scratch base, unlike a context
# named scratch matching FROM scratch, which stays the empty base.
run_case "stage-name context replaces a scratch base" "" err "overridden by --build-context" --build-context builder=docker-image://alpine:latest <<'EOF'
FROM scratch AS builder
EOF

# Oracle: with --build-context DOCKER.io/library/alpine=docker-image://
# cgr.dev/chainguard/static:latest the outline loads
# docker.io/library/alpine:latest under [internal]; the context is
# accepted by buildx but matches nothing, because splitDockerDomain keeps
# the domain case and the two hosts compare byte-exact. alpine stays the
# base and stays rejected.
run_case "uppercase-host context name does not match a lowercase FROM" "" err "alpine" --build-context DOCKER.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
RUN echo hi
EOF

# Oracle: the all-lowercase spelling of the same context loads static
# under [context alpine]; together with the case above this pins the
# byte-exact host comparison.
run_case "lowercase-host context name matches the FROM the uppercase one missed" "" ok "" --build-context docker.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
RUN echo hi
EOF

# Oracle: with --build-context INDEX.docker.io/library/alpine=... the
# outline loads docker.io/library/alpine:latest under [internal]; the
# index.docker.io to docker.io mapping applies only to the exact lowercase
# spelling, so this name matches nothing and alpine stays rejected.
run_case "uppercase index.docker.io context name does not map or match" "" err "alpine" --build-context INDEX.docker.io/library/alpine=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM alpine
RUN echo hi
EOF

# Oracle: FROM Foo/bar with the byte-identical context Foo/bar loads only
# static under [context Foo/bar]; splitDockerDomain treats a dotless
# first component that is not all-lowercase as a domain (domain Foo, path
# bar), so the reference is valid and the context matches it.
run_case "dotless uppercase first component is a domain and matches its context" "" ok "" --build-context Foo/bar=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM Foo/bar
RUN echo hi
EOF

# Oracle: with the lowercased context foo/bar the outline loads
# Foo/bar:latest under [internal] and fails resolving the host Foo; the
# two spellings are different references, so nothing matches and Foo/bar
# is checked as written, off the allowlist.
run_case "lowercased context does not match an uppercase-domain FROM" "" err "Foo/bar" --build-context foo/bar=docker-image://cgr.dev/chainguard/static:latest <<'EOF'
FROM Foo/bar
RUN echo hi
EOF

# --- artifact sources ------------------------------------------------------
# COPY --from and RUN --mount=from name external artifact sources, which
# the registry rules permit as report entries; only FROM lines meet the
# allowlist. The oracle prints each one for the report; this gate reads
# FROM lines only. Oracle: the run passes with the artifact source printed.
run_case "external COPY --from artifact source is not a base" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/static:latest
COPY --from=busybox:latest /bin/busybox /busybox
EOF

run_case "external RUN mount source is not a base" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN --mount=from=alpine,target=/mnt echo hi
EOF

# Oracle: docker.io/library/alpine:latest is rejected as a base; a
# reference that is both a FROM base and a COPY source is a base, so the
# artifact allowance cannot launder it.
run_case "a base doubling as a copy source is still a base" "" err "alpine" <<'EOF'
FROM alpine
COPY --from=alpine /etc/os-release /o
EOF

# Oracle: the final stage resolves docker.io/library/alpine:latest. The
# FROM inside the heredoc body is file content, so it registers no stage
# alias, and the later "FROM alpine" is an external image.
run_case "heredoc body cannot launder a stage alias" "" err "alpine" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base AS build
COPY <<INNER /tmp/f
FROM cgr.dev/chainguard/wolfi-base AS alpine
INNER
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; the FROM in the
# heredoc body is file content, not an instruction.
run_case "FROM inside a heredoc body does not count" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<INNER /tmp/f
FROM ubuntu:22.04
INNER
RUN echo done
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; both heredoc
# bodies are consumed in order, F1 first and F2 second.
run_case "COPY with two heredocs consumes both bodies in order" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<F1 <<F2 /tmp/dir/
FROM ubuntu:22.04
F1
FROM alpine:3.20
F2
RUN echo done
EOF

# Oracle: docker.io/library/ubuntu:22.04 is resolved for the second stage.
# The tab-indented INNER line terminates the <<- heredoc (leading tabs are
# stripped for the comparison), so the FROM after it is a real instruction.
run_case "tab-indented delimiter ends a <<- heredoc" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN <<-INNER
	echo hi
	INNER
FROM ubuntu:22.04
EOF

# Oracle: docker.io/library/alpine:latest is resolved for a second stage.
# Under escape=` the backslash is not a continuation character, so the
# "FROM alpine" line is a real instruction.
run_case "escape directive disables backslash continuation" "" err "alpine" <<'EOF'
# escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi \
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. Under escape=`
# the backtick continues the RUN line, which swallows the "FROM alpine"
# text.
run_case "escape directive enables backtick continuation" "" ok "" <<'EOF'
# escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi `
FROM alpine
EOF

# Oracle: BuildKit fails the file with "invalid escape token ';' does not
# match ` or \", so no base pulls from it and the check reports the value.
run_case "invalid escape directive value is unverified" "" warn "invalid escape" <<'EOF'
# escape=;
FROM cgr.dev/chainguard/wolfi-base
EOF

# Oracle: BuildKit fails the file with "only one escape parser directive
# can be used", so no base pulls from it and the check reports the
# duplicate, keeping the first value.
run_case "duplicate escape directive is unverified" "" warn "only one escape parser directive" <<'EOF'
# escape=\
# escape=\
FROM cgr.dev/chainguard/wolfi-base
EOF

# Oracle: docker.io/library/alpine:latest is resolved for a second stage.
# A line ending in two escape characters is not a continuation; BuildKit
# requires the character before the final escape to not be the escape.
run_case "line ending in two escape characters does not continue" "" err "alpine" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi \\
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. Trailing
# whitespace after the escape character still continues the line, so the
# "FROM alpine" text is swallowed into the RUN.
run_case "trailing whitespace after the escape still continues" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi \ 
FROM alpine
EOF

# Oracle: docker.io/library/alpine:latest is resolved. A plain comment
# ends the parser-directive block, so the escape directive after it is
# inert and the backtick does not continue the RUN line.
run_case "escape directive after a plain comment is inert" "" err "alpine" <<'EOF'
# a comment
# escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi `
FROM alpine
EOF

# Oracle: docker.io/library/alpine:latest is resolved. An unknown key in
# directive shape also ends the directive block.
run_case "escape directive after an unknown key is inert" "" err "alpine" <<'EOF'
# foo=bar
# escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi `
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. Directive keys
# are case-insensitive, so # ESCAPE=` is honored and the backtick
# continues the RUN line.
run_case "escape directive key is case-insensitive" "" ok "" <<'EOF'
# ESCAPE=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi `
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. Leading
# whitespace before a parser directive is allowed and the directive is
# honored.
run_case "parser directive with leading whitespace is honored" "" ok "" <<'EOF'
   # escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi `
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. check is a known
# directive key, so it does not end the directive block and the escape
# directive after it is honored.
run_case "check directive does not end the directive block" "" ok "" <<'EOF'
# check=skip=all
# escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi `
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. An empty line
# inside a continuation draws a BuildKit warning but the instruction
# continues, so the "FROM ubuntu" text is swallowed into the RUN.
run_case "empty continuation line does not end the instruction" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi \

FROM ubuntu:22.04
EOF

# Oracle: docker.io/library/builder2:latest is resolved for the second
# stage. BuildKit joins continued lines without a separator, so the ref is
# builder2, not the declared alias builder.
run_case "continuation joins without a separator" "" err "builder2" <<'EOF'
FROM cgr.dev/chainguard/go:latest AS builder
FROM builder\
2
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. A comment line
# inside a continuation is dropped and the continuation goes on, so the
# FROM alpine text is swallowed into the RUN.
run_case "comment inside a continuation does not end it" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi \
# a comment
FROM alpine
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. BuildKit's lexer
# attaches the word after a bare << as the heredoc delimiter, so the body
# is consumed as content.
run_case "separated << NAME heredoc is recognized" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat << F1
FROM ubuntu:22.04
F1
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; the quoted
# separated delimiter works the same way.
run_case "separated quoted heredoc delimiter is recognized" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat << 'F1'
FROM ubuntu:22.04
F1
EOF

# Oracle: BuildKit resolves docker.io/library/ubuntu:22.04 and then fails
# on "unknown instruction: F1". "<<- F1" with a space is not a heredoc
# (the dash blocks the lexer's whitespace attachment), so the FROM line is
# a real instruction.
run_case "separated <<- NAME is not a heredoc" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat <<- F1
FROM ubuntu:22.04
F1
EOF

# Oracle: docker.io/library/ubuntu:22.04 is resolved for the second stage;
# a bare << at the end of the line opens no heredoc, so the FROM line after
# it is a real instruction.
run_case "bare << at end of line is not a heredoc" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo <<
FROM ubuntu:22.04
EOF

# Oracle: docker.io/library/ubuntu:22.04 is resolved for the second stage;
# a marker whose rest contains another < (<<<F1, the shell herestring
# spelling) is not a heredoc to BuildKit, so the FROM line after it is a
# real instruction.
run_case "marker with an additional < is not a heredoc" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat <<<F1
FROM ubuntu:22.04
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; a leading file
# descriptor digit (2<<F1) still starts a heredoc.
run_case "file-descriptor heredoc marker is recognized" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN true 2<<F1
FROM ubuntu:22.04
F1
EOF

# Oracle: docker.io/library/ubuntu:22.04 is resolved for the second stage.
# The delimiter comparison is exact, so the "F1 " line with a trailing
# space does not terminate the heredoc; the bare F1 line does.
run_case "delimiter line with trailing whitespace does not terminate" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<F1 /tmp/f
F1 
F1
FROM ubuntu:22.04
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. The "F1 " line
# with a trailing space is heredoc content, not the delimiter, so the FROM
# text after it stays content too.
run_case "content after a trailing-whitespace near-delimiter stays content" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<F1 /tmp/f
F1 
FROM ubuntu:22.04
F1
RUN echo done
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; heredocs are
# detected on the joined logical line, after continuations.
run_case "heredoc on a continued instruction line" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<F1 \
/tmp/f
FROM ubuntu:22.04
F1
RUN echo done
EOF

# Oracle: docker.io/library/ubuntu:22.04 is resolved for the second stage;
# the single-quoted heredoc name ends at the matching body line and the
# FROM after it is a real instruction.
run_case "single-quoted heredoc name is recognized and terminated" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN <<'F1'
echo hi
F1
FROM ubuntu:22.04
EOF

# Oracle: docker.io/library/ubuntu:22.04 is resolved for the second stage,
# the same as the single-quoted form.
run_case "double-quoted heredoc name is recognized" "" err "ubuntu:22.04" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN <<"F1"
echo hi
F1
FROM ubuntu:22.04
EOF

# Oracle: BuildKit fails the file with "unterminated heredoc", so no base
# pulls from it and the check reports it.
run_case "unterminated heredoc is unverified" "" warn "unterminated heredoc" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<F1 /tmp/f
some content
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; BuildKit treats
# $F1 as a literal delimiter name. The check cannot classify such a marker
# with certainty, so it reports the marker and stops the scan there: the
# lines after it cannot be told apart from heredoc content.
run_case "heredoc marker with a dollar sign is unverified" "" warn "not supported by this check" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat <<$F1
FROM ubuntu:22.04
$F1
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; ONBUILD RUN, COPY,
# and ADD lines open heredocs like their plain forms, and the body is
# content.
run_case "ONBUILD heredoc body is content" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
ONBUILD RUN <<F1
FROM ubuntu:22.04
F1
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. After the glued
# whitespace of a separated << the dash belongs to the delimiter, so this is
# a heredoc named -EOF2 with no tab chomping.
run_case "separated delimiter starting with a dash" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat << -EOF2
FROM ubuntu:22.04
-EOF2
EOF

# Oracle: docker.io/library/alpine:latest is resolved for the final stage.
# The << inside the double-quoted string is plain text to BuildKit (its
# heredoc lexer splits the line into shell words first), so no heredoc opens
# on the first RUN, the FROM alpine line is a real instruction, and the
# later RUN <<EOT is the only heredoc.
run_case "heredoc marker inside double quotes is plain text" "" err "alpine" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo " <<EOT "
FROM alpine
RUN <<EOT
echo hi
EOT
EOF

# Oracle: docker.io/library/alpine:latest is resolved for the final stage,
# the same as the double-quoted form.
run_case "heredoc marker inside single quotes is plain text" "" err "alpine" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo ' <<EOT '
FROM alpine
RUN <<EOT
echo hi
EOT
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. A real heredoc
# after a quoted string on the same line still opens, so the FROM in the
# body is content.
run_case "real heredoc after a quoted string still opens" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo "x" <<EOF2
FROM ubuntu:22.04
EOF2
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. The backslash
# escapes the quote, so no string opens and the <<EOF2 word is a heredoc.
run_case "escaped quote before a heredoc marker" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo \" <<EOF2
FROM ubuntu:22.04
EOF2
EOF

# Oracle: docker.io/library/alpine:latest is resolved. BuildKit's heredoc
# lexer errors on the unbalanced quote and silently scans no heredocs on the
# line (verified), so the FROM alpine line is a real instruction. The check
# reports the quote as UNVERIFIED, continues with no heredoc open exactly as
# BuildKit does, and rejects the alpine base it then reads, so the known
# off-allowlist base still fails the file.
run_case "unbalanced quote then a bad FROM is still rejected" "" err "alpine" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo "oops <<EOF2
FROM alpine
EOF

# The same construct with nothing bad after it: the quote is reported, the
# scan continues, and the run is UNVERIFIED rather than a pass or a
# rejection.
run_case "unbalanced quote alone is unverified" "" warn "unbalanced double quote" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo "oops <<EOF2
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. BuildKit hardcodes
# backslash as the escape character of its heredoc lexer even under
# escape=`, so the quote is escaped and <<EOT is a heredoc whose body
# swallows the FROM alpine line.
run_case "heredoc lexing escapes with backslash even under escape=backtick" "" ok "" <<'EOF'
# escape=`
FROM cgr.dev/chainguard/wolfi-base
RUN echo \" <<EOT
FROM alpine
EOT
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. BuildKit detects
# the heredoc (words split at the spaces the expansion carries), but an
# expansion with whitespace shifts word boundaries this check cannot
# follow, so it reports the expansion and stops the scan there instead of
# guessing whether the lines after it are content; the file after the stop
# holds no decision, so the run is UNVERIFIED, not a rejection of the
# heredoc body.
run_case "expansion with whitespace on a heredoc line is unverified" "" warn "not supported on a heredoc-capable instruction" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo ${A:-x y} <<EON
FROM ubuntu:22.04
EON
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; the stable
# docker/dockerfile:1 frontend parses these constructs as the builtin
# frontend does.
run_case "stable syntax directive is accepted" "" ok "" <<'EOF'
# syntax=docker/dockerfile:1
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# A non-rolling frontend may parse the file by different rules than this
# check implements, so the pin is reported as UNVERIFIED, the scan
# continues under the rolling rules as a best effort, and the oracle runs
# the pinned frontend itself.
run_case "non-rolling syntax directive is unverified" "" warn "syntax directive" <<'EOF'
# syntax=docker/dockerfile:1-labs
FROM cgr.dev/chainguard/wolfi-base
EOF

# The pinned rolling-era shape from the brief: a pin plus a Chainguard
# FROM. The pin is named in the UNVERIFIED line and nothing else in the
# file is off the allowlist, so the run is exit 3, not a rejection.
run_case "pinned rolling-era frontend with a Chainguard FROM is unverified" "" warn "docker/dockerfile:1.6" <<'EOF'
# syntax=docker/dockerfile:1.6
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; the outline run
# resolves docker.io/docker/dockerfile:1 as the frontend, the same rolling
# tag the bare spelling names.
run_case "rolling syntax tag with the docker.io prefix is accepted" "" ok "" <<'EOF'
# syntax=docker.io/docker/dockerfile:1
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# The adversarial reproduction from the 2026-09-14 check, verbatim. BuildKit
# under the pinned docker/dockerfile:1.0 frontend treats the heredoc body as
# ordinary instructions, so the FROM alpine inside it is a real stage and
# the real build fails at the next line (Dockerfile parse error line 5:
# unknown instruction: EOT), pulling nothing; the 1.0 frontend has no
# subrequest support, so the oracle run under it fails with unsupported
# frontend capability moby.buildkit.frontend.subrequests, which is not a
# pass. This check names the pin in an UNVERIFIED line and reads the rest
# under the rolling rules, where the body is content, so nothing rejects.
run_case "pinned syntax tag 1.0 is unverified before heredoc parsing" "" warn "syntax directive 'docker/dockerfile:1.0'" <<'EOF'
# syntax=docker/dockerfile:1.0
FROM cgr.dev/chainguard/wolfi-base:latest AS app
RUN echo build <<EOT
FROM docker.io/library/alpine:latest AS smuggled
EOT
EOF

# Oracle: a real build of the same shape under 1.3 fails with dockerfile
# parse error on line 5: unknown instruction: EOT (did you mean ENV?); 1.3
# also predates heredocs.
run_case "pinned syntax tag 1.3 is unverified" "" warn "syntax directive 'docker/dockerfile:1.3'" <<'EOF'
# syntax=docker/dockerfile:1.3
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: docker/dockerfile:1.4.0 parses heredocs, but its outline run is
# answered by a different frontend (buildx pulled docker/dockerfile:1.8.1
# by digest to service the subrequest, re-confirmed 2026-09-17), so an
# outline pass under this pin vouches for a different parser than the pin;
# the UNVERIFIED line says the textual expansion assumes the rolling
# syntax.
run_case "pinned syntax tag 1.4.0 is unverified" "" warn "syntax directive 'docker/dockerfile:1.4.0'" <<'EOF'
# syntax=docker/dockerfile:1.4.0
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: a real build fails to resolve docker.io/docker/dockerfile:1.99
# (not found), pulling nothing.
run_case "pinned syntax tag 1.99 is unverified" "" warn "syntax directive 'docker/dockerfile:1.99'" <<'EOF'
# syntax=docker/dockerfile:1.99
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: outline fails with invalid context name Docker/Dockerfile:1:
# invalid reference format: repository name (Dockerfile) must be lowercase,
# pulling nothing. The check matches the directive value byte for byte, so
# a case variant never passes as the rolling tag.
run_case "uppercase syntax directive value is unverified" "" warn "syntax directive 'Docker/Dockerfile:1'" <<'EOF'
# syntax=Docker/Dockerfile:1
FROM cgr.dev/chainguard/wolfi-base
EOF

# A line in directive position shaped like a directive with an unknown key
# ends the block, as the rolling frontend reads it (pinned by the inert
# escape case above); a future frontend could honor it, so the check names
# the key in an UNVERIFIED line and reads it as a comment.
run_case "unknown directive-shaped key is unverified" "" warn "'foo'" <<'EOF'
# foo=bar
FROM cgr.dev/chainguard/wolfi-base
RUN echo hi
EOF

# Oracle: docker.io/library/alpine:latest is resolved; the second
# assignment on the ARG line reassigns BASE, matching docker build.
run_case "second assignment on an ARG line is processed" "" err "alpine" <<'EOF'
ARG BASE=cgr.dev/chainguard/wolfi-base
ARG OTHER=value BASE=alpine
FROM ${BASE}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved via the second
# assignment token.
run_case "multi-assignment ARG resolving to an allowed image" "" ok "" <<'EOF'
ARG OTHER=value BASE=cgr.dev/chainguard/wolfi-base
FROM ${BASE}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved; :- substitutes the
# default when the variable is unset.
run_case "colon-dash default applies when unset" "" ok "" <<'EOF'
ARG BASE
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved; the set value wins
# over the :- default.
run_case "colon-dash keeps the set value" "" ok "" <<'EOF'
ARG BASE=cgr.dev/chainguard/wolfi-base
FROM ${BASE:-alpine}
EOF

# Oracle: docker.io/library/alpine:latest is resolved; the set value
# alpine wins over the allowed :- default.
run_case "colon-dash set to a forbidden image is rejected" "" err "alpine" <<'EOF'
ARG BASE=alpine
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved; :- treats an empty
# value as unset and substitutes the default.
run_case "colon-dash default applies when empty" "" ok "" <<'EOF'
ARG BASE=
FROM ${BASE:-cgr.dev/chainguard/wolfi-base}
EOF

# Oracle: docker.io/library/alpine:latest is resolved; :+ substitutes the
# alternate when the variable is set and non-empty.
run_case "colon-plus substitutes when set" "" err "alpine" <<'EOF'
ARG EXTRA=1
FROM ${EXTRA:+alpine}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved; :+ expands to nothing
# when the variable is unset.
run_case "colon-plus expands to nothing when unset" "" ok "" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base${EXTRA:+-bad}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved; :+ treats an empty
# value as unset.
run_case "colon-plus expands to nothing when empty" "" ok "" <<'EOF'
ARG EXTRA=
FROM cgr.dev/chainguard/wolfi-base${EXTRA:+-bad}
EOF

# Oracle: cgr.dev/chainguard/wolfi-base is resolved; :- works inside an
# ARG default value too.
run_case "colon-dash inside an ARG default" "" ok "" <<'EOF'
ARG BASE=${OTHER:-cgr.dev/chainguard/wolfi-base}
FROM ${BASE}
EOF

# Oracle: BuildKit resolves docker.io/library/alpine:latest for this file
# (the % modifier trims the suffix). The check reports the modifier instead
# of emulating it, and the FROM that reads the value is unverified too; the
# oracle resolves the file and rejects alpine.
run_case "unsupported modifier in FROM is unverified, not emptied" "" warn "unsupported variable modifier" <<'EOF'
ARG BASE=alpine-x
FROM ${BASE%-x}
EOF

# Oracle: BuildKit resolves docker.io/library/alpine:latest for this file.
# The check reports the modifier in the ARG default the same way instead of
# silently expanding it to an empty string.
run_case "unsupported modifier in an ARG default is unverified" "" warn "unsupported variable modifier" <<'EOF'
ARG OTHER=alpine-x
ARG BASE=${OTHER%-x}
FROM ${BASE}
EOF

# Oracle: docker.io/library/alpine:3.20 is resolved (the colon-less -
# modifier substitutes its default only when the variable is undeclared or
# undefined, not when it is empty). The check reports the colon-less forms
# instead of emulating them.
run_case "colon-less minus modifier is unverified, not emulated" "" warn "unsupported variable modifier" <<'EOF'
ARG BASE
FROM ${BASE-docker.io/library/alpine:3.20}
EOF

# Oracle: a real cacheonly build of ARG A="x y" B=alpine with
# FROM ${B:-cgr.dev/chainguard/wolfi-base} resolves
# docker.io/library/alpine:latest (2026-09-17): BuildKit reassembles the
# quoted line and still assigns B. The check does not model that
# reassembly, so the line is reported and every later variable read is
# unverified; the literal Chainguard FROM here stays verifiable, so the
# run is exit 3, and the companion case below pins that a variable FROM
# after the tainted line is never a pass.
run_case "quoted ARG value spanning whitespace is unverified" "" warn "cannot take apart" <<'EOF'
ARG A="x y" B=alpine
FROM cgr.dev/chainguard/wolfi-base
EOF

# The tainted-line reproduction: BuildKit resolves alpine (the real build
# above), a scan that skipped the line and applied the :- default would
# pass wolfi-base, so the FROM must be unverified, not a pass.
run_case "variable FROM after an unverifiable ARG line is unverified" "" warn "cannot take apart" <<'EOF'
ARG A="x y" B=alpine
FROM ${B:-cgr.dev/chainguard/wolfi-base}
EOF

# A name assigned again after the unverifiable line is certain again, as
# in BuildKit (a later assignment beats whatever the tainted line set), so
# only the tainted line itself is reported.
run_case "assignment after an unverifiable ARG line is certain again" "" warn "cannot take apart" <<'EOF'
ARG A="x y" B=alpine
ARG B=cgr.dev/chainguard/wolfi-base
FROM ${B}
EOF

# Oracle: a real cacheonly build of this file resolves only
# cgr.dev/chainguard/wolfi-base:latest (2026-09-17): BuildKit reassembles
# the quoted second line and assigns BASE the Chainguard base over the
# alpine from line 1. The value a line before the tainted one gave a name
# is stale after it, so the FROM is unverified on the uncertain line,
# never rejected on the stale alpine; the exit 3 is the discriminator,
# because a scan that kept trusting line 1 exits 1 here.
run_case "tainted ARG line does not leave an earlier value trusted" "" warn "ARG at line 2 has a quoted value" <<'EOF'
ARG BASE=alpine
ARG OTHER="x y" BASE=cgr.dev/chainguard/wolfi-base
FROM $BASE
EOF

# Oracle: a real cacheonly build of ARG OTHER=a\ B=alpine with the same
# FROM resolves cgr.dev/chainguard/wolfi-base:latest (2026-09-17): the
# escaped whitespace swallows B= into the value of OTHER, the reverse of
# the quoted case above. The check models neither join, so both lines are
# reported rather than guessed at.
run_case "escape character in an ARG value is unverified" "" warn "escape character" <<'EOF'
ARG OTHER=a\ BASE=alpine
FROM cgr.dev/chainguard/wolfi-base
EOF

run_case "variable FROM after an escaped ARG line is unverified" "" warn "escape character" <<'EOF'
ARG OTHER=a\ B=alpine
FROM ${B:-cgr.dev/chainguard/wolfi-base}
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. A UTF-8 byte order
# mark before the parser directives is discarded and the escape directive
# after it is honored, so the backtick continuation swallows the FROM alpine
# text. The fixture is built with printf because a literal byte order mark in
# this file would be invisible.
printf '\357\273\277# escape=`\nFROM cgr.dev/chainguard/wolfi-base\nRUN echo hi `\nFROM alpine\n' > "$tmp/Dockerfile"
out=$(sh "$SCRIPT" "$tmp/Dockerfile" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  pass=$((pass + 1))
else
  failcount=$((failcount + 1))
  echo "FAIL: byte order mark before directives — expected pass, got exit $rc: $out"
fi

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. BuildKit splits
# words on Unicode spaces (here a no-break space between echo and <<EON), so
# the heredoc opens and its body swallows the FROM. The check splits
# bytewise, so it cannot tell whether the heredoc opens: it reports the line
# as UNVERIFIED and stops the scan there, and the FROM ubuntu in what
# BuildKit reads as the body is not rejected. The fixture is built with
# printf because a literal no-break space in this file would be invisible.
printf 'FROM cgr.dev/chainguard/wolfi-base\nRUN echo\302\240<<EON\nFROM ubuntu:22.04\nEON\n' > "$tmp/Dockerfile"
out=$(sh "$SCRIPT" "$tmp/Dockerfile" 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then
  case "$out" in
    *UNVERIFIED*"Unicode space"*) pass=$((pass + 1)) ;;
    *)
      failcount=$((failcount + 1))
      echo "FAIL: Unicode space on a heredoc line — output should name the Unicode space in an UNVERIFIED line, got: $out"
      ;;
  esac
else
  failcount=$((failcount + 1))
  echo "FAIL: Unicode space on a heredoc line — expected exit 3, got exit $rc: $out"
fi

# The following four fixtures are built with printf because their deciding
# bytes (a lone CR, a NUL, CRLF endings) would be invisible or impossible in
# a heredoc here. Each is fed to run_case by redirection, which keeps the
# pass counters in this shell.

# Oracle: outline fails with dockerfile parse error on line 1: FROM requires
# either one or three arguments; BuildKit keeps the CR inside the line, so
# nothing pulls. The check cannot split such a line the way BuildKit does,
# so it reports the byte in an UNVERIFIED line and does not scan the file.
printf 'FROM cgr.dev/chainguard/wolfi-base:latest\rFROM docker.io/library/alpine:latest\n' > "$tmp/bare-cr.bin"
run_case "bare CR joining two FROMs is unverified" "" warn "contains a CR" < "$tmp/bare-cr.bin"

# Oracle: outline fails with dockerfile parse error on line 1: FROM requires
# either one or three arguments; BuildKit keeps the NUL inside the line, so
# nothing pulls. awk implementations disagree about NUL bytes in input, so
# the check reports the byte in an UNVERIFIED line and does not scan the
# file.
printf 'FROM cgr.dev/chainguard/wolfi-base:latest\000FROM docker.io/library/alpine:latest\n' > "$tmp/nul.bin"
run_case "NUL byte in a FROM line is unverified" "" warn "contains a NUL byte" < "$tmp/nul.bin"

# Oracle: outline resolves cgr.dev/chainguard/wolfi-base:latest with exit 0;
# CRLF line endings stay accepted.
printf 'FROM cgr.dev/chainguard/wolfi-base:latest\r\nRUN echo hi\r\n' > "$tmp/crlf.bin"
run_case "CRLF line endings are accepted" "" ok "" < "$tmp/crlf.bin"

# Oracle: outline resolves cgr.dev/chainguard/wolfi-base:latest with exit 0,
# so BuildKit reads a final CR with no LF as an ordinary line ending. Once
# awk has split the file into records that CR cannot be told apart from a
# CRLF ending, so the check reports it as UNVERIFIED instead of scanning.
printf 'FROM cgr.dev/chainguard/wolfi-base:latest\r' > "$tmp/cr-eof.bin"
run_case "CR as the final byte with no LF is unverified" "" warn "contains a CR" < "$tmp/cr-eof.bin"

# Oracle: a stage is never its own base, so FROM alpine AS alpine pulls
# alpine (pinned by the oracle suite's live case 8). No other stage bears
# the name, so the deferred classification decides it is a pull, off the
# allowlist.
run_case "a base identical to its own stage name is rejected" "" err "alpine" <<'EOF'
FROM alpine AS alpine
EOF

# The count-line reproduction from the oracle review, held against this
# check too: artifact-capable is an ordinary bare reference
# (docker.io/library/artifact-capable), no stage bears the name, and it is
# off the allowlist.
run_case "FROM artifact-capable is rejected as a bare reference" "" err "artifact-capable" <<'EOF'
FROM artifact-capable
EOF

# The scan continues past an advisory construct so every one is listed:
# the two unsupported modifiers must both appear as UNVERIFIED diagnostics
# naming their own lines, and the count excludes the summary line (which
# also spells UNVERIFIED), so a scan that stopped after the first
# construct cannot pass on the summary's token.
cat > "$tmp/Dockerfile" <<'EOF'
ARG A=alpine-x
ARG B=${A%x}
ARG C=${A#a}
FROM cgr.dev/chainguard/wolfi-base
EOF
out=$(sh "$SCRIPT" "$tmp/Dockerfile" 2>&1); rc=$?
nwarn=$(printf '%s\n' "$out" | grep -c '^check-from-lines: UNVERIFIED')
if [ "$rc" -ne 3 ] || [ "$nwarn" -ne 2 ]; then
  failcount=$((failcount + 1))
  echo "FAIL: advisory scan continues — expected exit 3 with exactly two UNVERIFIED diagnostics besides the summary, got exit $rc with $nwarn: $out"
else
  case "$out" in
    *'in "${A%...}" at line 2'*)
      case "$out" in
        *'in "${A#...}" at line 3'*) pass=$((pass + 1)) ;;
        *)
          failcount=$((failcount + 1))
          echo "FAIL: advisory scan continues — the line 3 modifier diagnostic is missing, got: $out"
          ;;
      esac
      ;;
    *)
      failcount=$((failcount + 1))
      echo "FAIL: advisory scan continues — the line 2 modifier diagnostic is missing, got: $out"
      ;;
  esac
fi

# A Dockerfile whose bare name contains '=' must still be read: a POSIX awk
# operand shaped like name=value is a variable assignment, not a filename, so
# the gate feeds the file on stdin. If that regresses, this forbidden FROM
# is never read and the gate prints OK.
printf 'FROM docker.io/library/python:3.12\n' > "$tmp/from=allowed"
out=$( (cd "$tmp" && sh "$SCRIPT" "from=allowed") 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *"docker.io/library/python:3.12"*) pass=$((pass + 1)) ;;
    *)
      failcount=$((failcount + 1))
      echo "FAIL: filename containing '=' — error should name the forbidden FROM, got: $out"
      ;;
  esac
else
  failcount=$((failcount + 1))
  echo "FAIL: filename containing '=' — forbidden FROM passed; the file was not read"
fi

echo ""
echo "test-check-from-lines: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
