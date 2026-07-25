#!/usr/bin/env bash
# ~/.config/agentbox/setup.sh — installs extra tools that aren't in the shared image.
#
# Runs INSIDE the container, ONCE per container (it re-runs automatically when this file's
# content changes). Keep it idempotent. Its full output is logged to
# /var/log/agentbox-setup.log (tail it with `ab logs`); on failure agentbox prints the exit
# code + the tail of that log to the container log, so the cause is visible without a second
# command.
#
# Why this fetches a binary instead of `apt-get install` — this IS the confinement:
#   setup.sh runs as the *unprivileged* agentbox user (uid matching your host uid), not root.
#   agentbox is a security boundary: tooling runs with no privileges and the inner dockerd is
#   confined by Sysbox, so there is deliberately no sudo / root available here. That means
#   setup.sh CANNOT `apt-get install` (apt needs root) — to add a tool it instead fetches a
#   portable, self-contained binary into a user-writable dir (~/.local/bin, already on PATH).
#   This works for *any* tool, packaged or not, and keeps the install off the privileged image
#   build. (micro itself happens to be apt-installable; we use it here to demonstrate the
#   unprivileged pattern you'd follow for a tool that genuinely isn't packaged.)
set -euo pipefail

# micro editor — a static, self-contained binary dropped into ~/.local/bin (on PATH).
if ! command -v micro >/dev/null 2>&1; then
  v=2.0.14
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  curl -fsSL "https://github.com/zyedidia/micro/releases/download/v${v}/micro-${v}-linux64-static.tar.gz" \
    | tar -xz -C "$t"
  install -m0755 "$t/micro-${v}/micro" "$HOME/.local/bin/micro"
fi
