#!/usr/bin/env bash
# agentbox entrypoint — runs as root inside the (Sysbox-isolated) container.
#   - "daemon" (or no args): start the inner rootful dockerd, hand its socket to the
#     agentbox user, then keep the container alive for `docker exec` sessions.
#   - any other command: ensure dockerd is up, then exec the command (as root).
#
# Sysbox confines this container, so a rootful inner dockerd is safe: it cannot reach
# the host. The agentbox user (uid matching the host user) is given access to the inner
# docker socket so `docker ...` works from `docker exec --user agentbox` sessions.
#
# The executable body is guarded by a BASH_SOURCE check so tests/run.sh can source this
# file to exercise ab_parse_port_line() without starting dockerd or chowning anything.
set -euo pipefail

DOCKER_SOCK=/var/run/docker.sock
DOCKERD_LOG=/var/log/dockerd.log
# Optional per-host customization dir (~/.config/agentbox on the host), mounted ro by ab.
# Absent → every helper below is a no-op, so other machines are unaffected.
AB_CFG=/home/agentbox/.config/agentbox
FORWARD_LOG=/var/log/agentbox-forward.log
SETUP_LOG=/var/log/agentbox-setup.log

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

# Parse one line of the ports file: echo the port number, or nothing if the line is a
# comment, blank, or not a bare integer. (A "2222:2222" map is rejected — only same-number
# host ports are supported.) Extracted so tests/run.sh can exercise it directly.
ab_parse_port_line() {
  local port
  port="$(printf '%s' "${1%%#*}" | tr -d '[:space:]')"
  # Always exit 0 (even when the line yields no port): the caller does
  # `port="$(ab_parse_port_line ...)"` under `set -e`, so a non-zero return here would kill
  # the entrypoint. An `if` (not `&&`) keeps the return status 0 regardless of the match.
  if [[ "$port" =~ ^[0-9]+$ ]]; then printf '%s' "$port"; fi
}

# Forward each host port declared in $AB_CFG/ports onto container loopback, so scripts that
# use 127.0.0.1:<port> (e.g. MAC_HOST=127.0.0.1 MAC_PORT=2222) reach the matching host
# service. Each forwarder is an in-container socat run as the unprivileged agentbox user,
# bridging 127.0.0.1:<port> -> host.docker.internal:<port> (the host gateway; ab adds the
# --add-host). Two host-side requirements: the service must listen on an interface reachable
# from the docker bridge (0.0.0.0, not 127.0.0.1-only), AND the host firewall must permit
# docker-bridge -> <port> (on NixOS: networking.firewall.interfaces.docker0.allowedTCPPorts).
# connect-timeout bounds the upstream connect so a blocked/unreachable service fails fast and
# is logged to $FORWARD_LOG (ab exec cat $FORWARD_LOG) instead of hanging (which would also
# leak a socat child per attempt). No-op without a ports file.
forward_ports() {
  [ -f "$AB_CFG/ports" ] || return 0
  if ! command -v socat >/dev/null 2>&1; then
    echo "agentbox: ports declared but 'socat' not in the image — rebuild it (ab rebuild)." >&2
    return 0
  fi
  local line port lead
  while IFS= read -r line || [ -n "$line" ]; do
    port="$(ab_parse_port_line "$line")"
    if [ -n "$port" ]; then
      echo "agentbox: forwarding container 127.0.0.1:$port -> host.docker.internal:$port" >&2
      setsid runuser -u agentbox -- socat \
        TCP-LISTEN:"$port",bind=127.0.0.1,fork,reuseaddr \
        TCP:host.docker.internal:"$port",connect-timeout=5 >>"$FORWARD_LOG" 2>&1 &
    else
      # Blank or #-comment lines legitimately yield no port — stay quiet for those. A line that
      # has non-comment content but isn't a bare integer (e.g. "2222:2222" — only same-number
      # host ports are supported) is a likely typo: name it instead of silently skipping it.
      lead="${line#"${line%%[![:space:]]*}"}"      # leading whitespace stripped
      case "$lead" in ''|'#'*) ;; *)
        echo "agentbox: ignoring malformed ports line: $line (expected a bare port, e.g. 2222)" >&2 ;;
      esac
    fi
  done < "$AB_CFG/ports"
}

# Print a loud, self-contained summary when setup.sh fails, so `ab logs` shows *why* without
# a second command: the exit code, the tail of the setup log, where to read the full log, and
# that it auto-retries next start. Non-fatal — the container stays up (claude/codex still work),
# and because no success marker is written, the next `ab start` re-runs setup.sh automatically.
# $SETUP_LOG is root-owned (the redirect is opened by this root subshell; only the setup.sh
# invocation drops to agentbox via runuser), so tailing it here is fine. Extracted as a function
# so tests/run.sh can exercise the message format directly.
ab_setup_fail() {
  local rc="$1"
  {
    echo "agentbox: ERROR — ~/.config/agentbox/setup.sh exited $rc (tool install incomplete)."
    echo "agentbox:        the container stays up; claude/codex still work."
    echo "agentbox:        ---- last 40 lines of setup output ----"
    { tail -n 40 "$SETUP_LOG" 2>/dev/null || true; } | sed 's/^/agentbox:        /'
    echo "agentbox:        ---- end ----"
    echo "agentbox:        full log: $SETUP_LOG   ->   ab exec cat $SETUP_LOG"
    echo "agentbox:        it auto-retries on the next 'ab start' (no marker was written)."
    echo "agentbox:        fix the script, then:  ab stop && ab start"
  } >&2
  echo "agentbox: setup.sh FAILED (exit $rc)." >>"$SETUP_LOG" 2>&1
}

# Non-fatal backstop for the daemon-step helpers (forward_ports / run_setup). Each is designed
# to return 0 on its own paths and to report its specific failures itself (forward_ports warns
# on a missing socat / a malformed port line; run_setup reports a setup.sh exit via
# ab_setup_fail). This catches the rare plumbing error that escapes a helper's own handling:
# name the step and point at its log so `ab logs` shows *what* failed without a second command.
# Called as `helper || ab_step_fail …`, so it also neutralizes set -e — the container stays up.
# Extracted so tests/run.sh can exercise the message directly.
ab_step_fail() {
  local step="$1" log="$2"
  {
    echo "agentbox: WARNING — $step reported a failure; the container stays up."
    echo "agentbox:        see $log   ->   ab exec cat $log"
    echo "agentbox:        fix it, then:  ab stop && ab start"
  } >&2
}

# Run the user's setup.sh once per container (re-runs when its content hash changes) to install
# extra tools. Backgrounded so `ab start` returns immediately; a failure is reported loudly to
# the container log via ab_setup_fail (visible in `ab logs`), not fatal.
run_setup() {
  [ -f "$AB_CFG/setup.sh" ] || return 0
  local hash marker
  hash="$(sha256sum "$AB_CFG/setup.sh" | cut -c1-16)"
  marker="/home/agentbox/.agentbox-setup-done-$hash"
  if [ -e "$marker" ]; then
    echo "agentbox: setup.sh unchanged since last run; skipping." >&2
    return 0
  fi
  echo "agentbox: running setup.sh (background)..." >&2
  (
    if runuser -u agentbox -- bash "$AB_CFG/setup.sh" >>"$SETUP_LOG" 2>&1; then
      runuser -u agentbox -- bash -c "umask 077 && touch '$marker'"
      echo "agentbox: setup.sh completed." >&2
      echo "agentbox: setup.sh completed." >>"$SETUP_LOG" 2>&1
    else
      ab_setup_fail "$?"
    fi
  ) &
}

# --- executable body (skipped when sourced for tests) ---------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  mkdir -p "${CARGO_TARGET_DIR:-/tmp/target}"
  chown agentbox: "${CARGO_TARGET_DIR:-/tmp/target}"

  if [ "$#" -eq 0 ] || [ "${1:-}" = "daemon" ]; then
    ensure_dockerd || true
    # In-container socat forwarders for declared ports, then the per-container setup.sh. Both
    # are best-effort conveniences — a failure names the step + points at its log (ab_step_fail)
    # rather than killing PID 1 (set -e) or being silently swallowed.
    forward_ports || ab_step_fail "port forwarding" "$FORWARD_LOG"
    run_setup || ab_step_fail "setup" "$SETUP_LOG"
    # Stay up so the container accepts `docker exec` sessions (dockerd runs as our child).
    exec tail -f /dev/null
  fi

  # Exec path: ensure the daemon is up, then run the requested command (as root).
  ensure_dockerd || true
  exec "$@"
fi
