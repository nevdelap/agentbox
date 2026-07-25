#!/usr/bin/env bash
# agentbox entrypoint — runs as root inside the (Sysbox-isolated) container.
#   - "daemon" (or no args): start the inner rootful dockerd, hand its socket to the
#     agentbox user, then keep the container alive for `docker exec` sessions.
#   - any other command: ensure dockerd is up, then exec the command (as root).
#
# Sysbox confines this container, so a rootful inner dockerd is safe: it cannot reach
# the host. The agentbox user (uid matching the host user) is given access to the inner
# docker socket so `docker ...` works from `docker exec --user agentbox` sessions.
set -euo pipefail

DOCKER_SOCK=/var/run/docker.sock
DOCKERD_LOG=/var/log/dockerd.log

ensure_dockerd() {
  if docker info >/dev/null 2>&1; then
    # Already up — make sure agentbox can reach the socket.
    chown agentbox:agentbox "$DOCKER_SOCK" 2>/dev/null || true
    return 0
  fi
  echo "agentbox: starting inner dockerd..." >&2
  dockerd >"$DOCKERD_LOG" 2>&1 &
  for _ in $(seq 1 60); do
    if [ -S "$DOCKER_SOCK" ] && docker info >/dev/null 2>&1; then
      chown agentbox:agentbox "$DOCKER_SOCK" 2>/dev/null || true
      echo "agentbox: inner dockerd ready." >&2
      return 0
    fi
    sleep 0.5
  done
  echo "agentbox: WARNING — inner dockerd did not start; see $DOCKERD_LOG" >&2
  return 1
}

mkdir -p "${CARGO_TARGET_DIR:-/tmp/target}"
chown agentbox: "${CARGO_TARGET_DIR:-/tmp/target}"

if [ "$#" -eq 0 ] || [ "${1:-}" = "daemon" ]; then
  ensure_dockerd || true
  # Stay up so the container accepts `docker exec` sessions (dockerd runs as our child).
  exec tail -f /dev/null
fi

# Exec path: ensure the daemon is up, then run the requested command (as root).
ensure_dockerd || true
exec "$@"
