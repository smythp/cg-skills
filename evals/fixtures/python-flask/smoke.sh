#!/usr/bin/env bash
# Smoke test for python-flask: start the container, expect HTTP 200 "ok" on /.
# Receives the image tag as $1. Exits 0 on success.
set -uo pipefail
IMAGE="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib.sh"

addr="$(run_detached "$IMAGE" 8080)" || exit 1
trap 'cleanup_container' EXIT

if ! wait_for_http "http://$addr/" 30; then
  echo "    no HTTP response from container" >&2
  docker logs "$E2E_CONTAINER" 2>&1 | sed 's/^/    /' >&2
  exit 1
fi

body="$(curl -fsS "http://$addr/" 2>/dev/null)"
[ "$body" = "ok" ] || { echo "    unexpected body: '$body'" >&2; exit 1; }
