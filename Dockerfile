# agentbox — a *confined* Ubuntu container for running the Claude Code and Codex
# CLIs, launched by the host as a **Sysbox** container (`docker run --runtime=sysbox-runc`).
#
# Sysbox isolates the container, so the inner Docker daemon runs **rootful inside the
# container** yet cannot reach the host — nested Docker with no `--privileged` and no
# host docker socket. Tooling (claude/codex/bash) runs as the unprivileged agentbox
# user; only the inner dockerd (PID 1) runs as root-in-container, which Sysbox confines.
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

FROM ubuntu:24.04

ARG HOST_UID=1000
ARG HOST_GID=100
ARG CLAUDE_CHANNEL=stable
ARG CODEX_RELEASE=latest

ENV DEBIAN_FRONTEND=noninteractive

# --- Enable universe, then install tools. NO python3 is pulled in. ---------
RUN sed -i 's/Components: main restricted/Components: main restricted universe/' \
      /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
          build-essential ca-certificates curl git jq just moreutils openssh-client ripgrep tmux \
    && rm -rf /var/lib/apt/lists/*

# --- Docker (official repo). The inner daemon is rootful; Sysbox isolates it. -
# A Sysbox container runs a normal rootful dockerd (no rootless extras, fuse-overlayfs,
# or slirp4netns needed).
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         docker-ce docker-ce-cli containerd.io \
         docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# --- uv (python is provided by uv on demand — no system python) ------------
RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin sh

# --- agentbox user matching host uid/gid ------------------------------------
# The ubuntu:24.04 base ships a built-in `ubuntu` user at uid 1000; remove any
# pre-existing user at HOST_UID first. Tooling (claude/codex/bash) runs as this
# user; the inner dockerd runs as root and is confined by Sysbox.
RUN existing="$(getent passwd "$HOST_UID" | cut -d: -f1)"; \
    if [ -n "$existing" ]; then userdel -r "$existing" || userdel "$existing"; fi; \
    if ! getent group "$HOST_GID" >/dev/null; then groupadd -g "$HOST_GID" agentbox; fi; \
    useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash agentbox; \
    usermod -aG docker agentbox

# --- From here, install as the agentbox user -------------------------------
USER agentbox
ENV HOME=/home/agentbox
# ~/.bin is bind-mounted from the host when present (see bin/ab); appended LAST so the
# image's installed tools (claude, codex, cargo, uv, …) take precedence and the user's
# scripts only ADD commands rather than shadow them (e.g. ~/.bin/claude wrapper).
# Harmless (empty PATH entry) if not mounted.
ENV PATH="/home/agentbox/.local/bin:/home/agentbox/.cargo/bin:/usr/local/bin:${PATH}:/home/agentbox/.bin"

# Rust (stable toolchain) + cargo-sweep
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile default
RUN cargo install cargo-sweep

# Claude Code (native glibc). Binaries live under ~/.local — a bind-mounted
# ~/.claude (config/auth) cannot shadow them. Updates disabled at runtime.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "$CLAUDE_CHANNEL"

# Codex (native musl-static; runs on glibc). Install into throwaway /tmp, then
# relocate the single static binary to /usr/local/bin so a bind-mounted ~/.codex
# (config/auth) cannot shadow the binary store.
USER root
RUN curl -fsSL https://chatgpt.com/codex/install.sh \
      | env CODEX_HOME=/tmp/codex-home CODEX_INSTALL_DIR=/tmp/codex-bin \
            CODEX_NON_INTERACTIVE=1 sh -s -- --release "$CODEX_RELEASE" \
    && install -m 0755 "$(readlink -f /tmp/codex-bin/codex)" /usr/local/bin/codex \
    && rm -rf /tmp/codex-home /tmp/codex-bin

# Interactive shells (`ab bash`, `docker exec -it … bash`) source ~/.bashrc on startup:
# the skip-permissions / never-ask aliases that are the point of running the CLIs inside
# agentbox.
COPY --chown=agentbox:agentbox .bashrc /home/agentbox/.bashrc

# Inner rootful dockerd data root (named volume `agentbox-docker` mounts here).
RUN mkdir -p /var/lib/docker
COPY --chmod=0755 agentbox-entrypoint.sh /usr/local/bin/agentbox-entrypoint

# Pin CLI versions (no auto-update); locale/term fallbacks; persist Rust build
# artifacts in /tmp so they survive across `docker exec` sessions and are only
# cleared when the container is torn down (`ab destroy`).
ENV DISABLE_UPDATES=1
ENV DISABLE_AUTOUPDATER=1
ENV LANG=C.UTF-8
ENV TERM=xterm-256color
ENV CARGO_TARGET_DIR=/tmp/target

# Runs as root: PID 1 starts the (Sysbox-isolated) inner dockerd. Tooling drops to
# the agentbox user via `docker exec --user agentbox` (see bin/ab).
USER root
WORKDIR /workspace
ENTRYPOINT ["agentbox-entrypoint"]
# "daemon" = start the inner dockerd and keep the container up for `docker exec`.
CMD ["daemon"]
