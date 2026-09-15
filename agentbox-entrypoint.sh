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
DOCKER_PID_FILE=/var/run/docker.pid
DOCKERD_LOG=/var/log/dockerd.log
DOCKER_READINESS_STATE_FILE=/var/run/agentbox/nested-docker-state
docker_readiness_operation_id="${AGENTBOX_OPERATION_ID:-unknown}"
DOCKER_READINESS_ATTEMPTS=60
DOCKER_READINESS_INTERVAL=0.5
DOCKER_READINESS_BOUND_SECONDS=30
docker_readiness_state=starting
docker_readiness_retryable=1
docker_readiness_replacement_attempted=0
docker_readiness_daemon_evidence=none
docker_readiness_wait_attempts=0
docker_readiness_diagnostic=""
docker_readiness_terminal_failure=0
docker_readiness_launch_observed=0
docker_readiness_launch_pid=""
# Per-project named volume mounted here by bin/ab. It contains jj's writable repo/workspace
# state, separate from the read-only host user config files supplied through JJ_CONFIG.
JJ_STATE_DIR=/home/agentbox/.config/jj
# Optional per-host customization dir (~/.config/agentbox on the host), mounted ro by ab.
# Absent → every helper below is a no-op, so other machines are unaffected.
AB_CFG=/home/agentbox/.config/agentbox
FORWARD_LOG=/var/log/agentbox-forward.log
SETUP_LOG=/var/log/agentbox-setup.log
# Which `ports` / `setup.sh` to use. ab resolves them per machine + project on the host (see
# ab_config_file in bin/ab: machines/<machine>/projects/<path>/… and its three fallbacks) and
# passes the winner here as a container-side path under the ro-mounted config dir. The defaults
# are the plain top-level files, so a container started WITHOUT ab — the bare `docker run` in
# the README — behaves exactly as it did before per-project config existed.
AB_PORTS_FILE="${AGENTBOX_PORTS_FILE:-$AB_CFG/ports}"
AB_SETUP_FILE="${AGENTBOX_SETUP_FILE:-$AB_CFG/setup.sh}"

docker_daemon_pid_alive() {
  local pid comm stat
  [ -r "$DOCKER_PID_FILE" ] || return 1
  read -r pid <"$DOCKER_PID_FILE" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
  [ "$comm" = dockerd ] || return 1
  stat="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
  case "$stat" in Z*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

docker_daemon_process_alive() {
  local pid comm stat
  while read -r pid comm stat; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    [ "$comm" = dockerd ] || continue
    case "$stat" in Z*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && return 0
  done < <(ps -eo pid=,comm=,stat= 2>/dev/null || true)
  return 1
}

docker_daemon_alive() {
  docker_daemon_pid_alive || docker_daemon_process_alive
}

docker_readiness_state_set() {
  local state="$1" evidence="${2:-$docker_readiness_daemon_evidence}" diagnostic="${3:-}"
  docker_readiness_state="$state"
  docker_readiness_daemon_evidence="$evidence"
  docker_readiness_diagnostic="$diagnostic"
  case "$state" in
    ready) docker_readiness_retryable=0; docker_readiness_terminal_failure=0 ;;
    failed-but-running|failed-and-exited|replacement-attempted)
      docker_readiness_retryable=1
      ;;
  esac
  printf 'agentbox: nested-docker state=%s evidence=%s%s\n' "$state" "$evidence" \
    "${diagnostic:+ diagnostic=$diagnostic}" >&2
  docker_readiness_state_write
}

docker_readiness_state_record() {
  printf 'operation_id=%s\n' "$docker_readiness_operation_id"
  printf 'state=%s\n' "$docker_readiness_state"
  printf 'retryable=%s\n' "$docker_readiness_retryable"
  printf 'replacement_attempted=%s\n' "$docker_readiness_replacement_attempted"
  printf 'daemon_evidence=%s\n' "$docker_readiness_daemon_evidence"
  printf 'wait_attempts=%s\n' "$docker_readiness_wait_attempts"
  printf 'wait_bound_seconds=%s\n' "$DOCKER_READINESS_BOUND_SECONDS"
  printf 'diagnostic=%s\n' "$docker_readiness_diagnostic"
}

docker_readiness_state_write() {
  local dir tmp
  [ -n "$DOCKER_READINESS_STATE_FILE" ] || return 0
  dir="${DOCKER_READINESS_STATE_FILE%/*}"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.nested-docker-state.XXXXXX" 2>/dev/null)" || return 0
  if ! docker_readiness_state_record >"$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  chmod 644 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$DOCKER_READINESS_STATE_FILE" 2>/dev/null || rm -f -- "$tmp"
  return 0
}

docker_socket_ready() {
  [ -S "$DOCKER_SOCK" ]
}

readiness_sleep() {
  sleep "$1"
}

docker_readiness_launched_process_alive() {
  local stat
  [[ "$docker_readiness_launch_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$docker_readiness_launch_pid" 2>/dev/null || return 1
  stat="$(ps -o stat= -p "$docker_readiness_launch_pid" 2>/dev/null || true)"
  case "$stat" in Z*) return 1 ;; esac
  return 0
}

docker_readiness_launched_process_exited() {
  local stat
  [[ "$docker_readiness_launch_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if ! kill -0 "$docker_readiness_launch_pid" 2>/dev/null; then
    return 0
  fi
  stat="$(ps -o stat= -p "$docker_readiness_launch_pid" 2>/dev/null || true)"
  case "$stat" in Z*) return 0 ;; esac
  return 1
}

wait_for_dockerd() {
  while [ "$docker_readiness_wait_attempts" -lt "$DOCKER_READINESS_ATTEMPTS" ]; do
    docker_readiness_wait_attempts=$((docker_readiness_wait_attempts + 1))
    if docker_socket_ready && docker info >/dev/null 2>&1; then
      chown agentbox:agentbox "$DOCKER_SOCK" 2>/dev/null || true
      return 0
    fi
    # Once a launched daemon has had time to appear, only positive termination evidence tied to
    # that launch PID authorizes the replacement path. A transient process-table miss must not
    # remove markers or start a duplicate daemon while the original launch is still progressing.
    if [ "$docker_readiness_launch_observed" = 1 ] &&
       [ "$docker_readiness_wait_attempts" -ge 2 ] &&
       docker_readiness_launched_process_exited; then
      return 2
    fi
    if [ "$docker_readiness_wait_attempts" -lt "$DOCKER_READINESS_ATTEMPTS" ]; then
      readiness_sleep "$DOCKER_READINESS_INTERVAL"
    fi
  done
  return 1
}

start_dockerd_once() {
  echo "agentbox: starting inner dockerd..." >&2
  docker_readiness_launch_observed=1
  dockerd >"$DOCKERD_LOG" 2>&1 &
  docker_readiness_launch_pid=$!
  if wait_for_dockerd; then
    echo "agentbox: inner dockerd ready." >&2
    return 0
  fi
  if docker_readiness_launched_process_alive || docker_daemon_alive; then
    echo "agentbox: WARNING — inner dockerd stayed alive but did not become ready; see $DOCKERD_LOG" >&2
    return 1
  fi
  if docker_readiness_launched_process_exited; then
    return 2
  fi
  return 1
}

ensure_dockerd() {
  local start_rc
  if docker info >/dev/null 2>&1; then
    # Already up — make sure agentbox can reach the socket.
    chown agentbox:agentbox "$DOCKER_SOCK" 2>/dev/null || true
    docker_readiness_state_set ready api-available
    return 0
  fi

  if [ "$docker_readiness_terminal_failure" = 1 ]; then
    docker_readiness_state_set failed-and-exited "$docker_readiness_daemon_evidence" \
      "replacement already attempted; start a fresh outer container recovery cycle"
    return 1
  fi
  docker_readiness_state=starting
  docker_readiness_retryable=1
  docker_readiness_replacement_attempted=0
  docker_readiness_daemon_evidence=none
  docker_readiness_wait_attempts=0
  docker_readiness_diagnostic=""
  docker_readiness_launch_observed=0
  docker_readiness_launch_pid=""
  docker_readiness_state_set starting launch-requested

  # An outer-container stop can leave Docker's Unix socket and PID file behind even
  # though the nested daemon was killed. Do not start a second daemon while a real
  # dockerd is still coming up; otherwise only remove the stale runtime markers before
  # starting a fresh daemon. This preserves the /var/lib/docker volume across restart.
  if docker_daemon_alive; then
    docker_readiness_daemon_evidence=live-dockerd
    if wait_for_dockerd; then
      docker_readiness_state_set ready live-dockerd
      return 0
    fi
    if docker_daemon_alive; then
      docker_readiness_state_set failed-but-running live-dockerd \
        "bounded readiness wait expired; see $DOCKERD_LOG"
      return 1
    fi
  fi

  # The daemon may have exited during readiness. Re-checking liveness above makes it safe
  # to clean its stale markers and make one controlled replacement attempt, without ever
  # starting a second daemon while the original is still alive.
  rm -f "$DOCKER_SOCK" "$DOCKER_PID_FILE"

  if start_dockerd_once; then
    docker_readiness_state_set ready launched
    return 0
  else
    start_rc=$?
  fi

  if [ "$start_rc" -ne 2 ]; then
    docker_readiness_state_set failed-but-running live-dockerd \
      "bounded readiness wait expired; see $DOCKERD_LOG"
    return 1
  fi
  if docker_daemon_alive; then
    docker_readiness_state_set failed-but-running live-dockerd \
      "daemon became live during recovery; refusing a duplicate start"
    return 1
  fi

  docker_readiness_state_set failed-and-exited daemon-exited \
    "daemon exited before readiness; attempting one replacement"
  rm -f "$DOCKER_SOCK" "$DOCKER_PID_FILE"
  docker_readiness_replacement_attempted=1
  docker_readiness_state_set replacement-attempted daemon-exited
  echo "agentbox: retrying inner dockerd once after it exited during readiness..." >&2
  if start_dockerd_once; then
    docker_readiness_state_set ready replacement
    return 0
  else
    start_rc=$?
  fi
  if [ "$start_rc" -eq 1 ] || docker_daemon_alive; then
    docker_readiness_state_set failed-but-running live-dockerd \
      "replacement daemon stayed alive but did not become ready; see $DOCKERD_LOG"
    return 1
  fi
  docker_readiness_terminal_failure=1
  docker_readiness_state_set failed-and-exited replacement-exited \
    "replacement daemon exited before readiness; start a fresh outer recovery cycle"
  echo "agentbox: WARNING — inner dockerd did not start after one recovery retry; see $DOCKERD_LOG" >&2
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

# Is a parsed port bindable by the unprivileged agentbox user? socat runs as agentbox, so it
# cannot bind a privileged port (<1024), and a valid port is 1024-65535. Surfacing this here
# (rather than letting socat fail to bind and only logging it) names a typo at start. Extracted
# (pure) so tests/run.sh can exercise it directly. Returns 0 (bindable) / 1 (not). The 10# forces
# decimal (a leading-zero port isn't read as octal), and the digit-count bound short-circuits
# before the arithmetic so an absurdly long number can't wrap a 64-bit int into a false pass.
ab_port_bindable() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( ${#p} <= 5 && 10#$p >= 1024 && 10#$p <= 65535 ))
}

# Forward each host port declared in $AB_PORTS_FILE onto container loopback, so scripts that
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
  [ -f "$AB_PORTS_FILE" ] || return 0
  if ! command -v socat >/dev/null 2>&1; then
    echo "agentbox: ports declared but 'socat' not in the image — rebuild it (ab rebuild)." >&2
    return 0
  fi
  local line port lead
  while IFS= read -r line || [ -n "$line" ]; do
    port="$(ab_parse_port_line "$line")"
    if [ -n "$port" ]; then
      if ! ab_port_bindable "$port"; then
        echo "agentbox: ignoring port $port (must be 1024-65535; socat binds as the unprivileged agentbox user)" >&2
        continue
      fi
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
  done < "$AB_PORTS_FILE"
}

# Print a loud, self-contained summary when setup.sh fails, so `ab logs` shows *why* without
# a second command: the exit code, the tail of the setup log, where to read the full log, and
# that it auto-retries next start. Non-fatal — the container stays up (claude/codex still work),
# and because no success marker is written, the next `ab start` re-runs setup.sh automatically.
# $SETUP_LOG is root-owned (the redirect is opened by this root subshell; only the setup.sh
# invocation drops to agentbox via runuser), so tailing it here is fine. Extracted as a function
# so tests/run.sh can exercise the message format directly.
# $2 is the setup script that actually ran — with four candidate locations per config file,
# naming the one that failed matters. Defaults to a bare "setup.sh" when omitted.
ab_setup_fail() {
  local rc="$1" path="${2:-setup.sh}"
  {
    echo "agentbox: ERROR — $path exited $rc (tool install incomplete)."
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

# A fresh Docker named volume is mounted root:root, even though the image's destination
# directory belongs to agentbox. Repair both fresh and previously-created volumes before any
# command (including jj) can use the state path. This volume is container-local, so recursively
# adopting its contents is safe and also repairs a volume first created by an older image.
ensure_jj_state() {
  install -d -o agentbox -g "$(id -g agentbox)" -m 0700 "$JJ_STATE_DIR"
  chown -R agentbox: "$JJ_STATE_DIR"
}

# Run the user's setup.sh once per container (re-runs when its content hash changes) to install
# extra tools. Backgrounded so `ab start` returns immediately; a failure is reported loudly to
# the container log via ab_setup_fail (visible in `ab logs`), not fatal.
run_setup() {
  [ -f "$AB_SETUP_FILE" ] || return 0
  local hash marker
  # Hash the CONTENT, not the path: switching to a differently-resolved setup.sh (a new
  # per-project one, say) re-runs it, while moving the same script between tiers does not.
  hash="$(sha256sum "$AB_SETUP_FILE" | cut -c1-16)"
  marker="/home/agentbox/.agentbox-setup-done-$hash"
  if [ -e "$marker" ]; then
    echo "agentbox: setup.sh unchanged since last run; skipping." >&2
    return 0
  fi
  echo "agentbox: running $AB_SETUP_FILE (background)..." >&2
  # setsid detaches the run into its own session, reparenting it to PID 1 (tini, via ab's
  # --init) so it's reaped on exit — instead of lingering as a zombie child of the
  # `tail -f /dev/null` the entrypoint execs into next (tail never wait()s). Same trick the
  # socat forwarders use, so the --init reap claim holds for setup.sh too. Inputs are passed
  # as positional args (not env) to keep the entrypoint's environment clean; ab_setup_fail is
  # exported so the detached shell can call it on failure.
  export -f ab_setup_fail
  # shellcheck disable=SC2016  # $1/$2/$3 are expanded by the inner bash -c, not this shell — but the `setsid` prefix stops shellcheck recognizing bash -c (so it thinks the $ are literal)
  setsid bash -c '
    setup="$1"; SETUP_LOG="$2"; marker="$3"
    if runuser -u agentbox -- bash "$setup" >>"$SETUP_LOG" 2>&1; then
      runuser -u agentbox -- bash -c "umask 077 && touch \"$marker\""
      echo "agentbox: setup.sh completed." >&2
      echo "agentbox: setup.sh completed." >>"$SETUP_LOG" 2>&1
    else
      ab_setup_fail "$?" "$setup"
    fi
  ' _ "$AB_SETUP_FILE" "$SETUP_LOG" "$marker" &
}

# --- executable body (skipped when sourced for tests) ---------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ensure_jj_state
  cargo_target_dir="${CARGO_TARGET_DIR:-/tmp/target}"
  mkdir -p "$cargo_target_dir"
  # A target directory left by an older container may already be owned by agentbox. Under
  # Sysbox, root cannot necessarily chown that existing directory again, even though the
  # runtime user can write it. Only repair ownership when a write check says it is needed;
  # otherwise an idempotent restart can die with EPERM before docker exec gets a chance to run.
  agentbox_can_write_dir() {
    local probe
    probe="$(runuser -u agentbox -- mktemp "$1/.agentbox-write-test.XXXXXX" 2>/dev/null)" || return 1
    runuser -u agentbox -- rm -f "$probe" >/dev/null 2>&1 || true
  }
  if ! agentbox_can_write_dir "$cargo_target_dir"; then
    chown agentbox: "$cargo_target_dir" 2>/dev/null || true
  fi
  if ! agentbox_can_write_dir "$cargo_target_dir"; then
    echo "agentbox: ERROR — $cargo_target_dir is not writable by agentbox." >&2
    exit 1
  fi

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
