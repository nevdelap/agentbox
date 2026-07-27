#!/usr/bin/env bash
#
# install-sysbox-ubuntu.sh — install the Sysbox runtime on an Ubuntu host so that
# agentbox (launched by `ab` with `docker run --runtime=sysbox-runc`) can run nested
# Docker securely — no --privileged, no host docker socket.
#
# Sysbox is a host prerequisite (like Docker itself). Run once on each Ubuntu host:
#
#   sudo bash install-sysbox-ubuntu.sh
#
# This downloads the official sysbox-ce .deb and installs it via apt. The package's
# postinst then registers the `sysbox-runc` docker runtime, enables the Sysbox
# services, applies the needed sysctls, and reloads docker. It also disables docker's
# `time-namespaces` feature, which sysbox v0.7.0 can't handle (see below).
#
set -euo pipefail

VERSION="${SYSBOX_VERSION:-0.7.0}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
URL="https://downloads.nestybox.com/sysbox/releases/v${VERSION}/sysbox-ce_${VERSION}-0.linux_${ARCH}.deb"
DEB="/tmp/sysbox-ce_${VERSION}-0.linux_${ARCH}.deb"

if [ "$(id -u)" -ne 0 ]; then
  echo "install-sysbox: must run as root (try: sudo bash $0)" >&2
  exit 1
fi

echo "install-sysbox: downloading sysbox-ce ${VERSION} (${ARCH})..."
curl -fsSL -o "$DEB" "$URL"

echo "install-sysbox: installing (apt)..."
apt-get update
apt-get install -y jq            # the Sysbox installer uses jq
apt-get install -y "$DEB"        # apt resolves the .deb's deps (incl. iptables)

# Docker 29.5+ enables a private `time` namespace for containers on supported kernels
# (moby/moby#52326). Sysbox's forked runc (v0.7.0) predates it and rejects the resulting
# `time` namespace in the OCI spec:
#   "OCI runtime create failed: namespace {"time" ""} does not exist"
# (https://github.com/nestybox/sysbox/issues/1011).
# Setting features.time-namespaces=false reverts to the pre-29.5
# spec sysbox expects. This mirrors what sysbox.nix does on NixOS via
# `virtualisation.docker.daemon.settings.features."time-namespaces" = false`.
DAEMON_JSON="/etc/docker/daemon.json"
echo "install-sysbox: disabling docker's time-namespaces feature in ${DAEMON_JSON}..."
mkdir -p /etc/docker
if [ -s "$DAEMON_JSON" ]; then
  cp -a "$DAEMON_JSON" "${DAEMON_JSON}.agentbox-bak"
  jq '.features."time-namespaces" = false' "${DAEMON_JSON}.agentbox-bak" > "$DAEMON_JSON"
else
  echo '{"features":{"time-namespaces":false}}' | jq . > "$DAEMON_JSON"
fi

echo "install-sysbox: restarting docker to apply..."
systemctl restart docker

echo
echo "install-sysbox: done. Verify:"
echo "  systemctl status sysbox"
echo "  docker info | grep -i runtime          # -> Runtimes: runc sysbox-runc"
echo "  docker run --runtime=sysbox-runc --rm hello-world"
