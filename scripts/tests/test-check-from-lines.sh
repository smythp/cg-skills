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

# run_case NAME MIRROR EXPECT CONTAINS [BUILDARG...]  (dockerfile on stdin)
#   EXPECT: ok  -> script must exit 0
#           err -> script must exit non-zero and output must contain CONTAINS
#   Each extra argument is passed as --build-arg NAME=value.
run_case() {
  name="$1"; mirror="$2"; expect="$3"; contains="$4"; shift 4
  cat > "$tmp/Dockerfile"
  # Fixture build-arg values contain no whitespace, so a string build with
  # unquoted expansion below is safe.
  extra=""
  for a in "$@"; do extra="$extra --build-arg $a"; done
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

run_case "build-arg with no matching ARG declaration is ignored" "" err '${BASE}' OTHER=cgr.dev/chainguard/python:latest-dev <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo hi
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
# match ` or \".
run_case "invalid escape directive value is rejected" "" err "invalid escape" <<'EOF'
# escape=;
FROM cgr.dev/chainguard/wolfi-base
EOF

# Oracle: BuildKit fails the file with "only one escape parser directive
# can be used".
run_case "duplicate escape directive is rejected" "" err "only one escape parser directive" <<'EOF'
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

# Oracle: BuildKit fails the file with "unterminated heredoc".
run_case "unterminated heredoc is rejected" "" err "unterminated heredoc" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
COPY <<F1 /tmp/f
some content
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved; BuildKit treats
# $F1 as a literal delimiter name. The gate cannot classify such a marker
# with certainty and refuses the file instead of guessing.
run_case "heredoc marker with a dollar sign fails closed" "" err "not supported by this gate" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN cat <<$F1
FROM ubuntu:22.04
$F1
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
# line, so the FROM alpine line is a real instruction. The gate cannot split
# the line either and refuses the file instead.
run_case "unbalanced quote on a heredoc-capable line fails closed" "" err "unbalanced double quote" <<'EOF'
FROM cgr.dev/chainguard/wolfi-base
RUN echo "oops <<EOF2
FROM alpine
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
# expansion with whitespace shifts word boundaries this gate cannot follow,
# so it refuses the file instead of guessing.
run_case "expansion with whitespace on a heredoc line fails closed" "" err "not supported on a heredoc-capable instruction" <<'EOF'
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

# A non-stable frontend may parse the file by different rules than this
# gate implements, so the gate refuses it. A conservative rejection,
# stated in the header.
run_case "non-stable syntax directive fails closed" "" err "syntax directive" <<'EOF'
# syntax=docker/dockerfile:1-labs
FROM cgr.dev/chainguard/wolfi-base
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
# (the % modifier trims the suffix). The gate rejects the modifier instead
# of emulating it; it may reject what Docker accepts, never the reverse.
run_case "unsupported modifier in FROM is rejected, not emptied" "" err "unsupported variable modifier" <<'EOF'
ARG BASE=alpine-x
FROM ${BASE%-x}
EOF

# Oracle: BuildKit resolves docker.io/library/alpine:latest for this file.
# The gate rejects the modifier in the ARG default the same way instead of
# silently expanding it to an empty string.
run_case "unsupported modifier in an ARG default is rejected" "" err "unsupported variable modifier" <<'EOF'
ARG OTHER=alpine-x
ARG BASE=${OTHER%-x}
FROM ${BASE}
EOF

# BuildKit reads the quoted value as one assignment spanning whitespace.
# The gate does not reassemble quoted whitespace; it refuses the line. A
# conservative rejection, stated in the header.
run_case "quoted ARG value spanning whitespace fails closed" "" err "cannot take apart" <<'EOF'
ARG A="x y" B=alpine
FROM cgr.dev/chainguard/wolfi-base
EOF

# BuildKit joins the escaped whitespace into one value. The gate refuses
# escape characters in ARG tokens instead of emulating the join. A
# conservative rejection, stated in the header.
run_case "escape character in an ARG value fails closed" "" err "escape character" <<'EOF'
ARG OTHER=a\ BASE=alpine
FROM cgr.dev/chainguard/wolfi-base
EOF

# Oracle: only cgr.dev/chainguard/wolfi-base is resolved. BuildKit splits
# words on Unicode spaces (here a no-break space between echo and <<EON), so
# the heredoc opens and its body swallows the FROM. The gate splits bytewise
# and refuses the file instead of guessing. The fixture is built with printf
# because a literal no-break space in this file would be invisible.
printf 'FROM cgr.dev/chainguard/wolfi-base\nRUN echo\302\240<<EON\nFROM ubuntu:22.04\nEON\n' > "$tmp/Dockerfile"
out=$(sh "$SCRIPT" "$tmp/Dockerfile" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *"Unicode space"*) pass=$((pass + 1)) ;;
    *)
      failcount=$((failcount + 1))
      echo "FAIL: Unicode space on a heredoc line — error should name the Unicode space, got: $out"
      ;;
  esac
else
  failcount=$((failcount + 1))
  echo "FAIL: Unicode space on a heredoc line — expected rejection, but it passed"
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
