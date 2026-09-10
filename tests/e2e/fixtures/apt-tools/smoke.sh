#!/usr/bin/env bash
# Smoke test for apt-tools: the image must have working curl and jq binaries.
set -uo pipefail
IMAGE="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib.sh"
trap 'cleanup_container' EXIT
timeout -k 30 60 docker run --rm --name "$E2E_CONTAINER" --entrypoint sh "$IMAGE" \
  -c "curl --version >/dev/null && jq --version >/dev/null"
