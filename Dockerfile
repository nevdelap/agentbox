# agentbox — a *confined* Ubuntu container for running the Claude Code and Codex
# CLIs, launched by the host as a **Sysbox** container (`docker run --runtime=sysbox-runc`).
#
# Sysbox isolates the container, so the inner Docker daemon runs **rootful inside the
# container** yet cannot reach the host — nested Docker with no `--privileged` and no
# host docker socket. Tooling (claude/codex/bash) runs as the unprivileged agentbox
# user; only the inner dockerd (and the tini init that `ab`'s `--init` runs as PID 1 to
# reap its children) run as root-in-container, which Sysbox confines.
# No system python — use `uv run python`.
#
# Host prerequisite: Sysbox must be installed + registered as a docker runtime on the
# host (see README.md; install-sysbox-ubuntu.sh on Ubuntu, the sysbox.nix NixOS module
# on NixOS). Build/run via the `ab` wrapper (it builds when stale and passes --runtime).
#
# Build:
#   docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) -t agentbox .
#
# Run (via `ab`; NOT privileged — Sysbox, not caps, provides the isolation):
#   docker run -d --runtime=sysbox-runc \
#     -v "$PWD":/workspace -v "$HOME/.claude":/home/agentbox/.claude \
#     -v "$HOME/.codex":/home/agentbox/.codex agentbox

FROM ubuntu:26.04

ARG HOST_UID=1000
ARG HOST_GID=100
ARG CLAUDE_CHANNEL=stable
ARG CODEX_RELEASE=latest
ARG JJ_VERSION=latest
ARG AGENTBOX_VERSION=unknown

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- Enable universe, then install tools. NO python3 is pulled in. ---------
RUN sed -i 's/Components: main restricted/Components: main restricted universe/' \
      /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt_version() { apt-cache policy "$1" | sed -n 's/^  Candidate: //p'; } \
    && apt-get install -y --no-install-recommends \
          build-essential="$(apt_version build-essential)" \
          ca-certificates="$(apt_version ca-certificates)" \
          curl="$(apt_version curl)" \
          gh="$(apt_version gh)" \
          git="$(apt_version git)" \
          jq="$(apt_version jq)" \
          just="$(apt_version just)" \
          moreutils="$(apt_version moreutils)" \
          openssh-client="$(apt_version openssh-client)" \
          ripgrep="$(apt_version ripgrep)" \
          socat="$(apt_version socat)" \
          tmux="$(apt_version tmux)" \
    && rm -rf /var/lib/apt/lists/*

# Jujutsu (Ubuntu's resolute repositories do not provide a binary package). Use the upstream
# musl release binary rather than compiling the large jj-cli crate. GitHub's latest-release API
# supplies the tag because the asset filename includes its version.
ARG TARGETARCH
RUN jj_tmp="$(mktemp -d)"; \
    trap 'rm -rf "$jj_tmp"' EXIT; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) jj_arch=x86_64 ;; \
      arm64) jj_arch=aarch64 ;; \
      *) echo "unsupported target architecture for jj: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac; \
    jj_version="$JJ_VERSION"; \
    if [ "$jj_version" = latest ]; then \
      jj_version="$(curl -fsSL https://api.github.com/repos/jj-vcs/jj/releases/latest | jq -er .tag_name)"; \
    fi; \
    curl -fsSL "https://github.com/jj-vcs/jj/releases/download/$jj_version/jj-$jj_version-$jj_arch-unknown-linux-musl.tar.gz" \
      | tar -xzf - -C "$jj_tmp"; \
    jj_bin="$(find "$jj_tmp" -type f -name jj -print -quit)"; \
    [ -n "$jj_bin" ] || { echo "jj binary missing from release archive" >&2; exit 1; }; \
    install -m 0755 "$jj_bin" /usr/local/bin/jj

# --- Docker (official repo). The inner daemon is rootful; Sysbox isolates it. -
# A Sysbox container runs a normal rootful dockerd (no rootless extras, fuse-overlayfs,
# or slirp4netns needed).
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && docker_codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $docker_codename stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt_version() { apt-cache policy "$1" | sed -n 's/^  Candidate: //p'; } \
    && apt-get install -y --no-install-recommends \
         docker-ce="$(apt_version docker-ce)" \
         docker-ce-cli="$(apt_version docker-ce-cli)" \
         containerd.io="$(apt_version containerd.io)" \
         docker-buildx-plugin="$(apt_version docker-buildx-plugin)" \
         docker-compose-plugin="$(apt_version docker-compose-plugin)" \
    && rm -rf /var/lib/apt/lists/*

# --- uv (python is provided by uv on demand — no system python) ------------
RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin sh

# --- agentbox user matching host uid/gid ------------------------------------
# The ubuntu:26.04 base ships a built-in `ubuntu` user at uid 1000; remove any
# pre-existing user at HOST_UID first. Tooling (claude/codex/bash) runs as this
# user; the inner dockerd runs as root and is confined by Sysbox.
RUN existing="$(getent passwd "$HOST_UID" | cut -d: -f1)"; \
    if [ -n "$existing" ]; then userdel -r "$existing" || userdel "$existing"; fi; \
    if ! getent group "$HOST_GID" >/dev/null; then groupadd -g "$HOST_GID" agentbox; fi; \
    useradd -l -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash agentbox; \
    usermod -aG docker agentbox

# Rust (stable toolchain) + cargo-sweep. Keep the toolchain shared and root-owned; cargo still
# defaults to the runtime user's writable $HOME/.cargo for registry/build state.
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH="/usr/local/cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | env CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup \
          sh -s -- -y --default-toolchain stable --profile default \
    && env CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup \
         /usr/local/cargo/bin/cargo install --root /usr/local cargo-sweep

# Claude Code (native glibc), installed through its signed apt repository so the binary and
# package metadata are root-owned rather than being created in the runtime user's home.
RUN case "$CLAUDE_CHANNEL" in \
      stable|latest) claude_channel="$CLAUDE_CHANNEL" ;; \
      *) echo "CLAUDE_CHANNEL must be stable or latest for the apt installation: $CLAUDE_CHANNEL" >&2; exit 1 ;; \
    esac; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
      -o /etc/apt/keyrings/claude-code.asc; \
    echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/$claude_channel $claude_channel main" \
      > /etc/apt/sources.list.d/claude-code.list; \
    apt-get update; \
    apt_version() { apt-cache policy "$1" | sed -n 's/^  Candidate: //p'; }; \
    apt-get install -y --no-install-recommends "claude-code=$(apt_version claude-code)"; \
    rm -rf /var/lib/apt/lists/*

# --- Runtime user -----------------------------------------------------------
USER ${HOST_UID}
ENV HOME=/home/agentbox
# /home/agentbox/.bin is on PATH by convention, but nothing mounts it by default — bind your own
# host script dir there via a `~/.bin` line in ~/.config/agentbox/mounts if you want one. Appended
# LAST so the image's installed tools (claude, codex, cargo, uv, …) take precedence and any
# mounted scripts only ADD commands rather than shadow them. Harmless (empty PATH entry) if
# nothing's mounted there.
ENV PATH="/home/agentbox/.local/bin:/home/agentbox/.cargo/bin:/usr/local/bin:${PATH}:/home/agentbox/.bin"

# Codex (native musl-static; runs on glibc). Install into throwaway /tmp, then relocate
# the whole release bin/ (codex plus sibling binaries it execs at runtime, e.g.
# codex-code-mode-host) to /usr/local/bin so a bind-mounted ~/.codex (config/auth)
# cannot shadow the binary store.
# The entrypoint must start rootful dockerd and repair mounted-volume ownership before it
# launches unprivileged docker-exec sessions. This is an intentional, human-authorized
# DL3002 exception; the runtime contract cannot be preserved by ending as agentbox.
# hadolint ignore=DL3002
USER 0

# Stable, image-baked identity for software running inside agentbox. This is
# deliberately a file rather than a host-configurable environment variable.
LABEL org.nevdelap.agentbox=true \
      org.nevdelap.agentbox.version=${AGENTBOX_VERSION}
RUN install -d -o root -g root -m 0555 /etc/agentbox \
 && printf 'agentbox=1\nversion=%s\n' "$AGENTBOX_VERSION" \
      > /etc/agentbox/identity \
 && chown root:root /etc/agentbox/identity \
 && chmod 0444 /etc/agentbox/identity

RUN curl -fsSL https://chatgpt.com/codex/install.sh \
      | env CODEX_HOME=/tmp/codex-home CODEX_INSTALL_DIR=/tmp/codex-bin \
            CODEX_NON_INTERACTIVE=1 sh -s -- --release "$CODEX_RELEASE" \
    && install -m 0755 "$(dirname "$(readlink -f /tmp/codex-bin/codex)")"/* /usr/local/bin/ \
    && rm -rf /tmp/codex-home /tmp/codex-bin

# Guard the "no system python" design goal (README): fail the build LOUD if any transitive apt
# dependency above sneaks python3 in. The image deliberately ships no python (uv provisions it on
# demand), so a leak here is a regression to catch at build time, not at runtime.
RUN if command -v python3 >/dev/null 2>&1; then \
      echo "agentbox: python3 present in the image — a dependency pulled it in; fix the apt install." >&2; \
      exit 1; \
    fi

# Interactive shells (`ab bash`, `docker exec -it … bash`) source ~/.bashrc on startup:
# the skip-permissions / never-ask aliases that are the point of running the CLIs inside
# agentbox.
COPY --chown=agentbox:$HOST_GID .bashrc /home/agentbox/.bashrc

# Inner rootful dockerd data root (named volume `agentbox-docker` mounts here).
# Writable jj repo/workspace state (the launcher mounts a per-project named volume here).
# The entrypoint repeats this ownership setup after the volume is mounted, including for
# volumes created before this directory was added to the image.
RUN mkdir -p /var/lib/docker \
 && install -d -o agentbox -g "$HOST_GID" -m 0700 /home/agentbox/.config/jj
COPY --chmod=0755 agentbox-entrypoint.sh /usr/local/bin/agentbox-entrypoint

# Pin CLI versions (no auto-update); locale/term fallbacks; persist Rust build
# artifacts in /tmp so they survive across `docker exec` sessions and are only
# cleared when the container is torn down (`ab destroy`).
#   - Claude Code: DISABLE_AUTOUPDATER=1 disables its built-in auto-updater (a real,
#     documented Claude Code env var), so a built image stays on the installed version.
#   - Codex: has no auto-updater at all — it never self-updates (the install.sh that pinned
#     CODEX_RELEASE is deleted above), so no env var is needed. (DISABLE_UPDATES was once set
#     here as a no-op; removed. Its startup update *check* can be silenced in ~/.codex/config.toml
#     on the host via check_for_update_on_startup=false, but that's host-owned, not image-baked.)
ENV DISABLE_AUTOUPDATER=1
ENV LANG=C.UTF-8
ENV TERM=xterm-256color
ENV CARGO_TARGET_DIR=/tmp/target

# Runs as root: the entrypoint starts the (Sysbox-isolated) inner dockerd. Tooling drops to
# the agentbox user via `docker exec --user agentbox` (see bin/ab). (At runtime `ab` passes
# --init, so docker's bundled tini is PID 1 and reaps the entrypoint's backgrounded children;
# the entrypoint itself runs as its child.)
WORKDIR /workspace
ENTRYPOINT ["agentbox-entrypoint"]
# "daemon" = start the inner dockerd and keep the container up for `docker exec`.
CMD ["daemon"]
