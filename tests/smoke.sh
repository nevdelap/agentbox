#!/usr/bin/env bash
# Integration smoke test for agentbox: against a RUNNING project container, verify the
# per-host customization (~/.config/agentbox) end-to-end — env vars, setup.sh tool install,
# and the loopback port forward — plus that the Sysbox confinement is unchanged.
#
# Run after starting the container for this repo:
#   ab start && bash tests/smoke.sh      # or: ab destroy && ab start && bash tests/smoke.sh
#
# Uses docker exec directly (no -it) so it runs unattended; sources bin/ab only to reuse
# compute_names() for the container name.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1";
         [ -n "${2:-}" ] && printf '       expected: %s\n' "$2";
         [ -n "${3:-}" ] && printf '       actual:   %s\n' "$3";
         FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "$2" "$3"; fi; }

# Container name for the CURRENT project (ab itself keys off $PWD), so this can be run from any
# project dir to test that project's container — e.g. from ~/stay it tests the stay container.
# Override the target with AGENTBOX_DIR=/path. (bin/ab is still sourced from the repo it lives in.)
# shellcheck disable=SC1091
source "$REPO/bin/ab"
compute_names "${AGENTBOX_DIR:-$PWD}"
set +e +u

if ! docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
  echo "smoke: container $cname is not running — start it first:  ab start" >&2
  exit 1
fi
dex() { docker exec --user agentbox "$cname" "$@"; }            # non-interactive exec
dexsh() { docker exec -i --user agentbox "$cname" bash; }       # pipe a script in

echo "env (ab --env-file ~/.config/agentbox/env)"
assert_eq "MAC_HOST" "127.0.0.1"        "$(dex printenv MAC_HOST)"
assert_eq "MAC_PORT" "2222"             "$(dex printenv MAC_PORT)"
assert_eq "MAC_DIR"  "/Users/nevd/stay" "$(dex printenv MAC_DIR)"

echo
echo "extra tool install (ab ran ~/.config/agentbox/setup.sh)"
# setup.sh runs in the background on start — poll up to 60s for micro to appear.
micro=""
for _ in $(seq 1 30); do
  micro="$(dex bash -lc 'command -v micro 2>/dev/null || true')"
  [ -n "$micro" ] && break
  sleep 2
done
assert_eq "micro installed" "/home/agentbox/.local/bin/micro" "$micro"

echo
echo "loopback port forward (container 127.0.0.1:2222 -> host -> mac ssh)"
# The forwarder is in-container socat; the macOS guest's sshd greets with an SSH banner.
# Retry briefly — the forwarder comes up a few seconds after the container starts.
banner=""
for _ in $(seq 1 10); do
  banner="$(printf '%s\n' \
    'timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/2222 && head -c 4 <&3" 2>/dev/null || true' \
    | dexsh)"
  [ "${banner:0:4}" = "SSH-" ] && break
  sleep 2
done
assert_eq "ssh banner via forwarder" "SSH-" "${banner:0:4}"

# On failure, pinpoint which layer is broken so the user knows what to fix (rather than just
# "expected SSH-"). The classic cause is the host firewall dropping docker-bridge -> :2222.
if [ "${banner:0:4}" != "SSH-" ]; then
  echo "  -- diagnosing the forward chain (which hop is broken?) --"
  fwd="$(docker exec --user agentbox "$cname" bash -c 'ps -eo args 2>/dev/null | grep -F "[s]ocat" | grep -F ":2222"' 2>/dev/null || true)"
  [ -n "$fwd" ] && echo "       in-container forwarder (socat :2222): UP" \
                || echo "       in-container forwarder (socat :2222): NOT running"
  hb="$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222 && head -c 4 <&3' 2>/dev/null || true)"
  [ "${hb:0:4}" = "SSH-" ] && echo "       host 127.0.0.1:2222 -> service: reachable" \
                          || echo "       host 127.0.0.1:2222 -> service: NOT reachable (is the host service up on 0.0.0.0?)"
  if [ "${hb:0:4}" = "SSH-" ]; then
    echo "       -> host reaches the service but the container does not: the host firewall is"
    echo "          likely dropping docker-bridge -> :2222. On NixOS:"
    echo "             networking.firewall.interfaces.docker0.allowedTCPPorts = [ 2222 ];"
  fi
fi

echo
echo "confinement unchanged (Sysbox, not --privileged)"
assert_eq "not privileged" "false" "$(docker inspect -f '{{.HostConfig.Privileged}}' "$cname")"
assert_eq "no caps added"   "null"  "$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$cname")"

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS: all %d smoke checks passed\n' "$PASS"
  exit 0
else
  printf 'FAIL: %d failed, %d passed\n' "$FAIL" "$PASS"
  exit 1
fi
