#!/usr/bin/env bash
# Smoke test for django: the installed Python deps must import cleanly.
# There is no CMD/ENTRYPOINT in this image (upstream sets it in docker-compose),
# so we override the entrypoint to run a Python import check.
set -uo pipefail
IMAGE="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib.sh"
trap 'cleanup_container' EXIT
bounded 60 docker run --rm --name "$E2E_CONTAINER" --entrypoint python "$IMAGE" -c \
  "import django, psycopg, PIL, sass; print('django', django.get_version())"
