#!/usr/bin/env bash
# Shared helpers for the guardener-dockerfile-migration e2e harness.
# Sourced by run.sh and by per-fixture smoke.sh scripts.
#
# Adapted from Adrian Mouat's dfc-skillz (amouat/dfc-skillz) tests/lib.sh.
# Changes from his version: containers run under a harness-supplied --name,
# ports publish on an ephemeral 127.0.0.1 port instead of a fixed host port
# on all interfaces (fixed ports collide between concurrent runs and expose
# the probe to the local network), and run_detached echoes the resolved
# host:port for the smoke test to probe.

# E2E_CONTAINER names every container a smoke run starts. run.sh exports a
# per-fixture value (migr-e2e-$RUN_ID-<fixture>-<purpose>); a standalone
# smoke.sh run gets a per-process fallback.
E2E_CONTAINER="${E2E_CONTAINER:-migr-e2e-$(date +%s)-$$-smoke}"

# wait_for_http URL [timeout_seconds]
# Polls URL until it returns any HTTP response, or times out.
wait_for_http() {
  local url="$1" timeout="${2:-30}" i
  for ((i = 0; i < timeout; i++)); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# run_detached IMAGE CONTAINER_PORT
# Runs IMAGE detached as $E2E_CONTAINER, publishing CONTAINER_PORT on an
# ephemeral 127.0.0.1 port, and echoes the resolved host:port.
run_detached() {
  local image="$1" cport="$2" addr
  timeout -k 30 60 docker run -d --rm --name "$E2E_CONTAINER" \
    -p "127.0.0.1::$cport" "$image" >/dev/null || return 1
  addr="$(docker port "$E2E_CONTAINER" "$cport" | head -n1)" || return 1
  [ -n "$addr" ] || return 1
  echo "$addr"
}

# cleanup_container -- remove this smoke run's container (ignores errors).
cleanup_container() {
  docker rm -f "$E2E_CONTAINER" >/dev/null 2>&1 || true
}
