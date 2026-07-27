# sysbox.nix — NixOS module that installs Sysbox (CE), the OCI runtime that lets
# the agentbox container run nested Docker *without* --privileged.
#
# Sysbox is not in nixpkgs (nixpkgs#271901). This module fetches the official
# upstream .deb (three static Go binaries) and sets up everything the Debian
# package's `postinst` does:
#   - the three systemd services (sysbox-mgr + sysbox-fs daemons; sysbox.service
#     wrapper that binds them and starts *before* docker),
#   - the docker runtime registration (`sysbox-runc`),
#   - the `sysbox` system user,
#   - the kernel sysctls Sysbox needs,
#   - the `/var/lib/sysboxfs` mountpoint.
#
# Copy to /etc/nixos/sysbox.nix and import from configuration.nix. Apply with:
# `sudo nixos-rebuild switch`.
# Source: sysbox-ce_0.7.0-0.linux_amd64.deb (downloads.nestybox.com).

{
  lib,
  pkgs,
  config,
  ...
}:

let
  # Sysbox package: fetch the upstream .deb and drop the three static binaries
  # into the Nix store. (We do NOT use the .deb's unit files; the services are
  # re-declared below so ExecStart points at store paths, not /usr/bin.)
  sysboxPkg = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "sysbox-ce";
    version = "0.7.0";

    src = pkgs.fetchurl {
      url = "https://downloads.nestybox.com/sysbox/releases/v${version}/sysbox-ce_${version}-0.linux_amd64.deb";
      hash = "sha256-7v8nNnFGe4+jUas9QHCXWUYtwD2fe1ChsgezeYLOQKk=";
    };

    nativeBuildInputs = [ pkgs.dpkg ];

    dontConfigure = true;
    dontBuild = true;

    unpackPhase = ''
      runHook preUnpack
      dpkg-deb -x $src .
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 usr/bin/sysbox-runc $out/bin/sysbox-runc
      install -Dm755 usr/bin/sysbox-mgr  $out/bin/sysbox-mgr
      install -Dm755 usr/bin/sysbox-fs   $out/bin/sysbox-fs
      runHook postInstall
    '';
  };

  # Host CLI tools the sysbox daemons shell out to. NixOS has no FHS /usr/bin, so these
  # must be on each daemon's PATH explicitly:
  #   - sysbox-mgr preflight (`progDeps` in its utils.go): rsync, modprobe (kmod),
  #     iptables — missing any, it exits "preflight check failed: <tool> is not
  #     installed on host".
  #   - sysbox-fs: fusermount3 (fuse3) — it emulates /proc & /sys inside sys containers
  #     over FUSE; without it, container creation dies with "FuseServer InitWait error".
  #   - runtime rootfs/network setup: util-linux (mount/losetup/nsenter), e2fsprogs
  #     (mkfs), iproute2 (ip).
  hostTools = [
    pkgs.rsync
    pkgs.kmod
    pkgs.iptables
    pkgs.fuse3
    pkgs.util-linux
    pkgs.e2fsprogs
    pkgs.iproute2
  ];
in
{
  # Docker runtime registration. Docker is already enabled in
  # configuration.nix; this just registers the sysbox-runc runtime so
  # `docker run --runtime=sysbox-runc ...` works.
  virtualisation.docker.daemon.settings.runtimes.sysbox-runc =
    lib.mkIf config.virtualisation.docker.enable
      { path = "${sysboxPkg}/bin/sysbox-runc"; };

  # Docker 29.5+ enables a private `time` namespace for containers on supported
  # kernels (moby/moby#52326). Sysbox's forked runc (v0.7.0) predates it and rejects
  # the resulting `time` namespace in the OCI spec:
  #   "OCI runtime create failed: namespace {"time" ""} does not exist"
  # (https://github.com/nestybox/sysbox/issues/1011). Disabling the feature reverts to
  # the pre-29.5 spec sysbox
  # expects, so importing this module alone makes sysbox usable — no separate
  # daemon.json tweak needed on the host.
  virtualisation.docker.daemon.settings.features."time-namespaces" =
    lib.mkIf config.virtualisation.docker.enable false;

  # `sysbox` system user (mirrors the .deb postinst's `useradd -s /bin/false sysbox`).
  users.users.sysbox = {
    isSystemUser = true;
    group = "sysbox";
  };
  users.groups.sysbox = { };

  # Kernel sysctls Sysbox recommends (from /lib/sysctl.d/99-sysbox-sysctl.conf).
  # mkOverride 2000 = lowest priority, so these are pure fallbacks: they apply
  # only where nothing else sets the value (e.g. nixpkgs defaults
  # fs.inotify.max_user_instances=524288, a max_user_watches=1048576 elsewhere,
  # and security.unprivilegedUsernsClone writes kernel.unprivileged_userns_clone).
  # Avoids any "defined multiple times" clash.
  boot.kernel.sysctl = {
    "fs.inotify.max_queued_events" = lib.mkOverride 2000 1048576;
    "fs.inotify.max_user_watches" = lib.mkOverride 2000 1048576;
    "fs.inotify.max_user_instances" = lib.mkOverride 2000 1048576;
    "kernel.keys.maxkeys" = lib.mkOverride 2000 20000;
    "kernel.keys.maxbytes" = lib.mkOverride 2000 1400000;
    "kernel.pid_max" = lib.mkOverride 2000 4194304;
  };

  # sysbox-fs mounts its virtual filesystems here.
  systemd.tmpfiles.rules = [ "d /var/lib/sysboxfs 0755 root root -" ];

  # ---- The three services (re-declared so ExecStart uses store paths). ----
  # Topology: sysbox-mgr + sysbox-fs are Type=notify daemons; sysbox.service is
  # a wrapper that binds both and must start *before* docker so docker picks up
  # the runtime cleanly.

  systemd.services.sysbox-mgr = {
    description = "sysbox-mgr (part of the Sysbox container runtime)";
    wantedBy = [ "sysbox.service" ];
    partOf = [ "sysbox.service" ];
    startLimitIntervalSec = 0;
    path = hostTools;
    serviceConfig = {
      Type = "notify";
      ExecStart = "${sysboxPkg}/bin/sysbox-mgr";
      NotifyAccess = "main";
      OOMScoreAdjust = -500;
      LimitNOFILE = "infinity";
      LimitNPROC = "infinity";
      TimeoutStartSec = 45;
      TimeoutStopSec = 90;
    };
  };

  systemd.services.sysbox-fs = {
    description = "sysbox-fs (part of the Sysbox container runtime)";
    wantedBy = [ "sysbox.service" ];
    partOf = [ "sysbox.service" ];
    after = [ "sysbox-mgr.service" ];
    startLimitIntervalSec = 0;
    path = hostTools;
    serviceConfig = {
      Type = "notify";
      ExecStart = "${sysboxPkg}/bin/sysbox-fs";
      NotifyAccess = "main";
      OOMScoreAdjust = -500;
      LimitNOFILE = "infinity";
      LimitNPROC = "infinity";
      TimeoutStartSec = 10;
      TimeoutStopSec = 10;
    };
  };

  systemd.services.sysbox = {
    description = "Sysbox container runtime";
    documentation = [ "https://github.com/nestybox/sysbox" ];
    # Must start before docker/containerd so `docker --restart` works with Sysbox.
    before = [
      "docker.service"
      "containerd.service"
    ];
    bindsTo = [
      "sysbox-mgr.service"
      "sysbox-fs.service"
    ];
    after = [
      "sysbox-mgr.service"
      "sysbox-fs.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.bash}/bin/sh -c '${sysboxPkg}/bin/sysbox-runc --version && ${sysboxPkg}/bin/sysbox-mgr --version && ${sysboxPkg}/bin/sysbox-fs --version && ${pkgs.coreutils}/bin/sleep infinity'";
    };
  };
}
