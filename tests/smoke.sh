#!/usr/bin/env bash
# Integration smoke test for agentbox: against a RUNNING project container, verify the
# per-host customization (~/.config/agentbox) end-to-end — env vars reach the container,
# setup.sh ran to completion, and a declared loopback port is forwarded — plus that the
# Sysbox confinement is unchanged (not privileged, no caps).
#
# Portable by design: each section derives its expectations from YOUR ~/.config/agentbox
# (not hardcoded values) and SKIPS itself when its config file is absent, so this runs —
# and passes the portable checks — on any host, not just the author's. The one piece that
# depends on a live host service (the end-to-end forward reachability) is reported as a
# diagnostic, not a hard fail.
#
# Run after starting the container for this repo:
#   ab start && bash tests/smoke.sh      # or: ab destroy && ab start && bash tests/smoke.sh
#
# Uses docker exec directly (no -it) so it runs unattended; sources bin/ab (for
# compute_names()) and agentbox-entrypoint.sh (for ab_parse_port_line()) — both are
# source-safe (executable bodies guarded by a BASH_SOURCE check).
#
# The executable body is guarded by a BASH_SOURCE check so tests/run.sh can source this
# file to exercise ab_parse_env_line() without a running container.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Test harness. Guarded so sourcing this file (tests/run.sh does, to unit-test
# ab_parse_env_line) doesn't redefine an already-present harness and shadow the caller's —
# which would otherwise make shellcheck -x flag the caller's helpers as unused (SC2329).
if ! declare -F ok >/dev/null 2>&1; then
  PASS=0
  FAIL=0
  ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
  fail() { printf '  FAIL %s\n' "$1";
           [ -n "${2:-}" ] && printf '       expected: %s\n' "$2";
           [ -n "${3:-}" ] && printf '       actual:   %s\n' "$3";
           FAIL=$((FAIL+1)); }
  assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "$2" "$3"; fi; }
fi

# Container name for the CURRENT project (ab keys off $PWD), so this can be run from any
# project dir to test that project's container. Override with AGENTBOX_DIR=/path.
# shellcheck disable=SC1091
source "$REPO/bin/ab"
# agentbox-entrypoint.sh defines ab_parse_port_line() (used in the ports section below).
# shellcheck disable=SC1091
source "$REPO/agentbox-entrypoint.sh"
compute_names "${AGENTBOX_DIR:-$PWD}"
set +e +u

# Non-interactive exec helpers (only used inside the guarded body, i.e. when run directly).
dex()   { docker exec --user agentbox "$cname" "$@"; }     # run a command
dexsh()  { docker exec -i --user agentbox "$cname" bash; } # pipe a script in

# Parse one line of the env file (~/.config/agentbox/env) the way docker's --env-file does:
# print "KEY<tab>VALUE", or nothing for a blank line or a full-line (#) comment. A line must
# contain at least one '='; everything after the FIRST '=' is the VALUE (an inline '#' is part
# of the value — docker does not treat it as a comment and does not strip quotes). Leading
# whitespace is ignored only when deciding whether the line is a comment. Extracted (and always
# returning 0) so tests/run.sh can exercise it directly under `set -e` with no Docker needed.
ab_parse_env_line() {
  local line="$1" trim
  trim="${line#"${line%%[![:space:]]*}"}"       # leading whitespace stripped (for the comment test only)
  case "$trim" in ''|'#'*) return 0 ;; esac      # blank or full-line comment -> emit nothing
  case "$line" in *=*) ;; *) return 0 ;; esac    # no '=' -> not an assignment
  printf '%s\t%s\n' "${line%%=*}" "${line#*=}"
}

# --- executable body (skipped when sourced for tests) ---------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

if ! docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
  echo "smoke: container $cname is not running — start it first:  ab start" >&2
  exit 1
fi

CFG="$HOME/.config/agentbox"

# ---- env (--env-file) -------------------------------------------------------
# Every KEY=VALUE in the host env file must reach the container intact (proves --env-file was
# applied at container creation). Parsed docker-style by ab_parse_env_line.
echo "env (ab --env-file ~/.config/agentbox/env)"
envf="$CFG/env"
if [ -f "$envf" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    parsed="$(ab_parse_env_line "$line")" || true
    [ -n "$parsed" ] || continue
    k="${parsed%%$'\t'*}"
    v="${parsed#*$'\t'}"
    assert_eq "env $k reached container" "$v" "$(dex printenv "$k")"
    n=$((n+1))
  done < "$envf"
  [ "$n" -eq 0 ] && echo "  (no KEY=VALUE lines in $envf)"
else
  echo "  -- no ~/.config/agentbox/env; skipping env checks"
fi

# ---- setup.sh ---------------------------------------------------------------
# setup.sh runs in the background on start and writes a content-hash completion marker on
# success (see agentbox-entrypoint.sh run_setup); assert the marker exists. Poll, because
# setup may still be running right after `ab start`.
echo
echo "extra tool install (ab ran ~/.config/agentbox/setup.sh)"
if [ -f "$CFG/setup.sh" ]; then
  marker=""
  for _ in $(seq 1 30); do
    marker="$(docker exec --user agentbox "$cname" bash -c 'ls /home/agentbox/.agentbox-setup-done-* 2>/dev/null | head -1' 2>/dev/null || true)"
    [ -n "$marker" ] && break
    sleep 2
  done
  assert_eq "setup.sh completed (marker present)" "1" "$([ -n "$marker" ] && echo 1 || echo 0)"
else
  echo "  -- no ~/.config/agentbox/setup.sh; skipping setup checks"
fi

# ---- loopback port forward --------------------------------------------------
# For the first declared port: assert the in-container socat forwarder is up (proves
# forward_ports wired it). End-to-end reachability is then reported as a DIAGNOSTIC — it
# needs a live host service on a bridge-reachable interface plus an open docker-bridge
# firewall, which is environment-specific (see README "Host firewall").
echo
echo "loopback port forward (container 127.0.0.1:<port> -> host gateway)"
portsf="$CFG/ports"
if [ -f "$portsf" ]; then
  port=""
  while IFS= read -r line || [ -n "$line" ]; do
    p="$(ab_parse_port_line "$line")"
    [ -n "$p" ] && { port="$p"; break; }
  done < "$portsf"
  if [ -n "$port" ]; then
    fwd="$(docker exec --user agentbox "$cname" bash -c "ps -eo args 2>/dev/null | grep -F '[s]ocat' | grep -F ':$port'" 2>/dev/null || true)"
    assert_eq "in-container forwarder (socat :$port) up" "1" "$([ -n "$fwd" ] && echo 1 || echo 0)"
    reach="$(printf '%s\n' "timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$port && head -c 4 <&3' 2>/dev/null || true" | dexsh)"
    if [ -n "$reach" ]; then
      echo "  -- end-to-end: container 127.0.0.1:$port reached the upstream (first bytes: $(printf '%q' "$reach"))"
    else
      echo "  -- end-to-end: container 127.0.0.1:$port did NOT reach an upstream in 3s (informational;"
      echo "                  needs a host service on 0.0.0.0:$port + an open docker-bridge firewall;"
      echo "                  the classic cause is the host firewall dropping docker-bridge -> :$port)."
    fi
  else
    echo "  -- no bare port declared in $portsf; skipping forward checks"
  fi
else
  echo "  -- no ~/.config/agentbox/ports; skipping forward checks"
fi

# ---- confinement (Sysbox, not --privileged) ---------------------------------
# Fully portable: independent of any per-host config.
echo
echo "confinement unchanged (Sysbox, not --privileged)"
assert_eq "not privileged" "false" "$(docker inspect -f '{{.HostConfig.Privileged}}' "$cname")"
assert_eq "no caps added"   "null"  "$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$cname")"
# #2 guard: the host config mounts (~/.config/home-manager, ~/.bin) must be read-only inside
# the container, so the agent can't write back to the host's dotfile source or drop scripts in
# ~/.bin. `test -w` is false on a read-only bind mount regardless of the dir's mode bits (the
# kernel denies writes to ro mounts), and true on a writable one — so it detects the mount's
# ro flag directly. Only checked when the dir exists in the container (i.e. the host had it);
# needs a container created AFTER the :ro flags (ab destroy && ab start).
for cdir in /home/agentbox/.config/home-manager /home/agentbox/.bin; do
  if docker exec --user agentbox "$cname" test -d "$cdir" 2>/dev/null; then
    assert_eq "$cdir mounted read-only" "false" \
      "$(docker exec --user agentbox "$cname" test -w "$cdir" 2>/dev/null && echo true || echo false)"
  fi
done

# ---- ab exec without a tty (#3) ----------------------------------------------
# The classic CI/pipe case: `ab exec <cmd>` (and `ab claude`/`ab codex`, which route here)
# with stdin NOT a terminal. The old hardcoded `-it` crashed here with "the input device is
# not a TTY"; cmd_exec now adds -t only when stdin IS a tty and sources ~/.bashrc via
# BASH_ENV regardless. Force the non-tty case (stdin from /dev/null) and confirm the command
# runs AND ~/.bashrc was sourced — `claude` resolves to a *function*, proof the bypass
# wrapper applies even headless (so `ab exec claude` in CI still gets
# --dangerously-skip-permissions, not the raw binary). Invokes the repo's bin/ab (not a
# docker-exec helper) so it exercises the real cmd_exec path.
echo
echo "ab exec without a tty (cmd_exec #3)"
n3="$(AGENTBOX_DIR="${AGENTBOX_DIR:-$PWD}" "$REPO/bin/ab" exec type claude </dev/null 2>/dev/null | head -1 | tr -d '\r')"
assert_eq "ab exec runs with no tty + sources .bashrc (claude is a function)" \
  "claude is a function" "$n3"

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS: all %d smoke checks passed\n' "$PASS"
  exit 0
else
  printf 'FAIL: %d failed, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi

fi
