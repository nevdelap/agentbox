# agentbox

A **confined** Ubuntu container for running the **Claude Code** and **Codex** CLIs,
with the tooling an agent needs: `git`, `ssh`, `uv`, `just`, `ripgrep`, `jq`, `tmux`,
`rustup` (stable toolchain) + `cargo-sweep`, and **nested Docker** for running CI
tooling. There is deliberately **no system python** — use `uv run python`.

Nested Docker is provided by **[Sysbox]**: the container is launched with
`docker run --runtime=sysbox-runc`, and the inner Docker daemon runs **rootful inside
the container** while Sysbox isolates it from the host.

[Sysbox]: https://github.com/nestybox/sysbox

## Confinement model

This container is a security boundary, so nested Docker runs under **Sysbox** rather
than privileged DinD:

- **No `--privileged`.** The outer container carries **zero** capabilities — Sysbox
  needs no caps, no seccomp relaxation, no devices. The *only* run flag is
  `--runtime=sysbox-runc`.
- The inner `dockerd` runs as **root inside the container**, but Sysbox confines it
  (container-root ≠ host-root), so a breakout — or the nested containers themselves —
  never reaches the host.
- **No host Docker socket** is mounted; nested Docker is fully self-contained.
- Tooling (claude/codex/bash) runs as the unprivileged **agentbox** user (uid matching
  your host uid); only the inner dockerd (PID 1) runs as root-in-container.

## Host prerequisite: install Sysbox

Sysbox must be installed and registered as a docker runtime on the host. It needs a root
system service, so it can't live inside the container image — install it once per host:

**Ubuntu** — run the installer in this repo:

```bash
sudo bash install-sysbox-ubuntu.sh
```

**NixOS** — Sysbox is not in nixpkgs (nixpkgs#271901). This repo ships a NixOS module,
[`sysbox.nix`](./sysbox.nix). Copy it into `/etc/nixos` and add it to your
`configuration.nix` imports:

```bash
sudo cp sysbox.nix /etc/nixos/sysbox.nix
```

```nix
  imports = [
    ./hardware-configuration.nix
    ./sysbox.nix # Sysbox runtime — secure unprivileged DinD for agentbox
  ];
```

```bash
sudo nixos-rebuild switch
```

The module fetches the upstream Sysbox `.deb` (three static binaries), declares the
`sysbox`/`sysbox-mgr`/`sysbox-fs` services, registers the `sysbox-runc` docker runtime,
creates the `sysbox` user, and applies Sysbox's recommended sysctls. The `.deb` URL + hash
are pinned for **amd64** (`x86_64`) hosts; an **arm64** NixOS host needs the `arm64` URL
and its own `hash` in [`sysbox.nix`](./sysbox.nix).

Verify on either host:

```sh
systemctl status sysbox
docker info | grep -i runtime        # -> Runtimes: runc sysbox-runc
```

## Usage

The launcher is [`bin/ab`](./bin/ab). Put it on your PATH — it locates the build context
(this repo root) from its own path, so a symlink works:

```bash
ln -s "$PWD/bin/ab" ~/.local/bin/ab
```

Run an agent on the current directory (the container auto-starts if it isn't running; your
cwd is mounted at `/workspace` and tooling runs as the unprivileged `agentbox` user):

```bash
ab claude            # Claude Code
ab codex             # Codex
ab bash              # interactive shell
ab exec make test    # any command
ab claude --resume   # extra args pass through to the CLI
```

Each project directory gets its own container. Lifecycle:

```bash
ab start             # create + start for this project (no-op if already running)
ab stop              # stop (kept on disk; /tmp build state preserved)
ab destroy           # stop + remove container + its inner-docker volume (/tmp state lost)
ab status            # is it running?
ab logs              # tail container / inner-dockerd logs
ab rebuild           # rebuild the image and recreate the container (then `ab claude`, etc.)
```

`ab start` and `rebuild` verify `sysbox-runc` is registered on the host and
exit with install guidance if it isn't. The image rebuilds automatically when the build
context changes.

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `AGENTBOX_DIR` | `$PWD` | project dir mounted at `/workspace` |
| `AGENTBOX_SSH` | `0` | set to `1` to also bind-mount `~/.ssh` (ro) for git push |
| `AGENTBOX_CONTEXT` | auto (repo root) | build context dir (override only if needed) |

## Mounts

- `$PWD` → `/workspace` (the project the agent works on)
- `~/.claude` → `/home/agentbox/.claude` (OAuth token, sessions, history)
- `~/.claude.json` → `/home/agentbox/.claude.json` (account/login state — the
  `oauthAccount` Claude Code checks to consider itself logged in; mounted only if present)
- `~/.codex` → `/home/agentbox/.codex` (auth, config)
- `~/.gitconfig` → `/home/agentbox/.gitconfig` (ro; git identity)
- `~/.config/home-manager` → `/home/agentbox/.config/home-manager` (if present; on hosts
  that manage `~/.bin` via home-manager, its entries resolve via the `/nix/store` ro mount
  or symlink into this tree)
- `~/.bin` → `/home/agentbox/.bin` (if present; on the container `PATH`)
- `/nix/store` → `/nix/store` (ro; NixOS only — so workspace `/nix/store` paths resolve)
- `~/.ssh` → `/home/agentbox/.ssh` (ro; only with `AGENTBOX_SSH=1`)
- named volume `agentbox-docker-<project>` → `/var/lib/docker` (per-project inner
  rootful docker state; `ab destroy` removes it)

## Nested Docker inside the container

```sh
ab bash
$ docker info              # shows a Server Version
$ docker run --rm hello-world
```

The inner docker socket is handed to the agentbox user by the entrypoint, so `docker`
works without `sudo` from `ab bash`/`ab exec` sessions.

## Requirements

- **Sysbox** installed + registered on the host (above).
- Docker on the host, and membership in the `docker` group.

## Build (without `ab`)

```bash
docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) -t agentbox .
docker run -d --runtime=sysbox-runc \
  -v "$PWD":/workspace -v "$HOME/.claude":/home/agentbox/.claude \
  -v "$HOME/.codex":/home/agentbox/.codex agentbox
```

## Version pinning

`CLAUDE_CHANNEL` (default `stable`) and `CODEX_RELEASE` (default `latest`) are
Dockerfile `ARG`s. Pin exact versions by building directly:

```bash
docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) \
             --build-arg CLAUDE_CHANNEL=2.1.89 \
             --build-arg CODEX_RELEASE=0.55.0 \
             -t agentbox .
```

Auto-updaters for both CLIs are disabled (`DISABLE_UPDATES=1` /
`DISABLE_AUTOUPDATER=1`), so a built image stays on its installed versions until you
rebuild.

## Notes

- The container user matches your host uid/gid, so files written to `/workspace` are
  owned by you on the host (no `root`-owned files, no git "dubious ownership" errors).
- The container's hostname matches the real host's (`--hostname "$(hostname)"`), so tools
  inside report the host's name rather than a container-ID hash.
- Python is absent by design: `uv` provisions Python on demand. Per the global rule,
  always run Python via `uv run python`.
- The Codex binary is a static musl build relocated to `/usr/local/bin/codex` so the
  bind-mounted `~/.codex` (config/auth) doesn't shadow it.
- Codex runs **without its own sandbox** (`--dangerously-bypass-approvals-and-sandbox`,
  wired in `~/.bashrc`): agentbox itself is the sandbox (Sysbox confinement), so Codex
  doesn't launch `bubblewrap`. That flag is documented as "intended solely for running in
  environments that are externally sandboxed," which is exactly agentbox — and Sysbox
  blocks the `/proc` mount `bwrap` would need anyway, so it wouldn't function even if
  installed (`bubblewrap` is therefore deliberately not installed).
