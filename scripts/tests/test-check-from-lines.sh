#!/bin/sh
# Fixture tests for check-from-lines.sh, ported from Guardener's
# TestValidateMigratedFROMs (chainguard-dev/mono
# containers/dfc/internal/agent/loop_validation_test.go), including every
# stage-alias case. Run from anywhere: ./test-check-from-lines.sh
#
# Dependencies: sh, awk. No network, no Docker.

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-from-lines.sh"
tmp="$(mktemp -d)" || exit 1
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
failcount=0

# run_case NAME MIRROR EXPECT CONTAINS  (dockerfile on stdin)
#   EXPECT: ok  -> script must exit 0
#           err -> script must exit non-zero and output must contain CONTAINS
run_case() {
  name="$1"; mirror="$2"; expect="$3"; contains="$4"
  cat > "$tmp/Dockerfile"
  if [ -n "$mirror" ]; then
    out=$(sh "$SCRIPT" --mirror "$mirror" "$tmp/Dockerfile" 2>&1); rc=$?
  else
    out=$(sh "$SCRIPT" "$tmp/Dockerfile" 2>&1); rc=$?
  fi
  if [ "$expect" = "ok" ]; then
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
    else
      failcount=$((failcount + 1))
      echo "FAIL: $name — expected pass, got exit $rc: $out"
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

run_case "scratch is allowed" "" ok "" <<'EOF'
FROM scratch
COPY hello /
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

run_case "unresolved ARG base is rejected" "" err '${BASE}' <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo hi
EOF

run_case "stage ARG cannot override global ARG used by later FROM" "" err "ubuntu:22.04" <<'EOF'
ARG BASE=ubuntu:22.04
FROM cgr.dev/chainguard/wolfi-base
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

run_case "stage ARG alone cannot satisfy FROM variable" "" err '${BASE}' <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
ARG BASE=cgr.dev/chainguard/python:latest-dev
FROM ${BASE}
RUN echo hi
EOF

run_case "missing base after platform flag is rejected" "" err "no image reference" <<'EOF'
FROM --platform=linux/amd64
RUN echo hi
EOF

run_case "empty ARG base is rejected" "" err '${BASE}' <<'EOF'
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

run_case "unresolved ARG inside cgr.dev path is rejected" "" err "unresolved ARG variable" <<'EOF'
ARG IMG
FROM cgr.dev/chainguard/$IMG:latest-dev
RUN echo hi
EOF

run_case "unresolved ARG inside external mirror path is rejected" "" err "unresolved ARG variable" <<'EOF'
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

echo ""
echo "test-check-from-lines: $pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
