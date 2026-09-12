#!/usr/bin/env bash
# Smoke test for distroless-go: running the image prints "Hello, world!" and exits 0.
set -uo pipefail
IMAGE="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib.sh"
trap 'cleanup_container' EXIT
out="$(bounded 60 docker run --rm --name "$E2E_CONTAINER" "$IMAGE" 2>&1)" \
  || { echo "    container exited non-zero: $out" >&2; exit 1; }
[ "$out" = "Hello, world!" ] || { echo "    unexpected output: '$out'" >&2; exit 1; }
