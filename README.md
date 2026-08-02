# agentbox

A **confined** Ubuntu container for running **Claude Code**, **Codex**, and **GitHub CLI**
(`gh`), with the tooling an agent needs: `git`, `ssh`, `uv`, `just`, `ripgrep`, `jq`, `tmux`,
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
  needs no caps, no seccomp relaxation, no devices. The run flags are just
  `--runtime=sysbox-runc` and `--init` (the latter inserts docker's bundled `tini` as
  PID 1 purely to reap the entrypoint's backgrounded children — it grants **no**
  capability, so the confinement is unchanged).
- The inner `dockerd` runs as **root inside the container**, but Sysbox confines it
  (container-root ≠ host-root), so a breakout — or the nested containers themselves —
  never reaches the host.
- **No host Docker socket** is mounted; nested Docker is fully self-contained.
- Tooling (claude/codex/bash) runs as the unprivileged **agentbox** user (uid matching
  your host uid); only the inner dockerd (and the `tini` init that `--init` runs as
  PID 1) run as root-in-container.

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

Both the Ubuntu installer and the NixOS module also disable docker's `time-namespaces`
feature. Docker 29.5+ gives containers a private `time` namespace on supported kernels
([moby/moby#52326](https://github.com/moby/moby/pull/52326)), which Sysbox v0.7.0's forked
runc rejects ([nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011)) —
every `ab` run would otherwise fail with:

```
OCI runtime create failed: namespace {"time" ""} does not exist
```

On Ubuntu that means `features.time-namespaces=false` in `/etc/docker/daemon.json` (the
installer merges it in with `jq`, backing up any existing file to
`daemon.json.agentbox-bak`, then restarts docker); on NixOS it's
`virtualisation.docker.daemon.settings.features."time-namespaces" = false`.

Verify on either host:

```sh
systemctl status sysbox
docker info | grep -i runtime        # -> Runtimes: runc sysbox-runc
docker run --runtime=sysbox-runc --rm hello-world
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
ab codex resume      # likewise for codex
```

Each project directory gets its own container. Lifecycle:

```bash
ab start [--grant-gh] [--grant-all-of-dot-ssh]                # create + start for this project
ab stop                                                       # stop (kept on disk; /tmp build state preserved)
ab destroy                                                    # stop + remove container + its inner-docker volume (/tmp state lost)
ab status                                                     # is it running?
ab config                                                     # which per-machine/per-project config files are in effect
ab logs                                                       # tail container / inner-dockerd logs
ab rebuild [--no-cache] [--grant-gh] [--grant-all-of-dot-ssh] # rebuild and recreate
ab --version                                                  # print the version
```

`ab start` and `rebuild` verify `sysbox-runc` is registered on the host and
exit with install guidance if it isn't. The image rebuilds automatically when the build
context changes.

### Updating bundled tools

`ab rebuild` may reuse cached install layers for the bundled Claude Code and Codex releases.
Run `ab rebuild --no-cache` when fresh CLI versions are required; the full rebuild is slower.

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `AGENTBOX_DIR` | `$PWD` | project dir mounted at `/workspace` |
| `AGENTBOX_CONTEXT` | auto (repo root) | build context dir (override only if needed) |
| `AGENTBOX_MACHINE` | `$(hostname)` | machine name used to look up per-machine config (does not change the container's hostname) |

Migration note: `AGENTBOX_SSH=1` is no longer supported and is silently ignored. Use
`ab start --grant-all-of-dot-ssh` (or `ab rebuild --grant-all-of-dot-ssh`) to grant the
container read-only access to the full `.ssh` directory, or use individual entries in
`~/.config/agentbox/mounts` for finer-grained access.

## Mounts

- `$PWD` → `/workspace` (the project the agent works on)
- `~/.claude` → `/home/agentbox/.claude` (OAuth token, sessions, history)
- `~/.claude.json` → `/home/agentbox/.claude.json` (account/login state — the
  `oauthAccount` Claude Code checks to consider itself logged in; mounted only if present)
- `~/.codex` → `/home/agentbox/.codex` (auth, config — e.g. `auth.json`, `config.toml`)
- `~/.config/gh` → `/home/agentbox/.config/gh` (GitHub CLI auth and config; only with `--grant-gh`)
- `~/.gitconfig` → `/home/agentbox/.gitconfig` (ro; git identity)
- `~/.config/agentbox` → `/home/agentbox/.config/agentbox` (ro, if present; see
  [Per-host and per-project customization](#per-host-and-per-project-customization-configagentbox)
  — env vars, host port forwards, extra tools)
- `/nix/store` → `/nix/store` (ro; NixOS only — so workspace `/nix/store` paths resolve)
- `/etc/localtime` → `/etc/localtime` (ro, if present on the host — so in-container time
  matches the host timezone)
- `~/.ssh` → `/home/agentbox/.ssh` (ro; only with `--grant-all-of-dot-ssh`)
- anything listed in `~/.config/agentbox/mounts` (ro unless the line ends `rw`; see
  [Per-host and per-project customization](#per-host-and-per-project-customization-configagentbox))
- named volume `agentbox-docker-<project>` → `/var/lib/docker` (per-project inner
  rootful docker state; `ab destroy` removes it)

The credential mounts are explicit grants. Use `ab start --grant-gh` or
`ab rebuild --grant-gh` to use and persist GitHub CLI credentials, and
`ab start --grant-all-of-dot-ssh` or `ab rebuild --grant-all-of-dot-ssh` to expose the
host `.ssh` directory read-only, with `known_hosts` mounted read-write when it exists so
SSH can persist newly learned hosts. For finer-grained SSH access, omit the SSH grant and
list individual files in `~/.config/agentbox/mounts`, for example:

```text
~/.ssh/config
~/.ssh/known_hosts rw
~/.ssh/id_ed25519
```

That keeps the selected files read-only except for `known_hosts`, which is writable.
Grant choices are stored on the container, so convenience commands reuse them after
`ab stop`; use `ab rebuild` without the grant flags to revoke them.

## Per-host and per-project customization (`~/.config/agentbox/`)

agentbox is portable by default, but a host can opt into extras by creating
`~/.config/agentbox/`. **If the directory is absent, agentbox behaves exactly as without it**
— other machines are unaffected. If present, it's mounted read-only and six optional files
each drive one mechanism (copy-pasteable samples live in
[`examples/agentbox-config/`](./examples/agentbox-config)):

| File | Shape | Effect |
|---|---|---|
| `env` | `KEY=VALUE` or bare `KEY` lines | passed to `docker run` via `--env-file`, and the names are forwarded again on every `ab bash` / `ab exec` / `ab claude` / `ab codex` invocation using the launching shell's current values. `KEY=VALUE` supplies the initial literal value; bare `KEY` imports the value from the host environment |
| `mounts` | one host path per line (`src` or `src dst`, optionally ending `ro`/`rw`; `#` comments) | each host path is bind-mounted into the container — **files and directories both** — read-only unless the line ends `rw`. A single `src` mounts at the same path, `src dst` at an explicit destination. A leading `~` is `$HOME` on the host and `/home/agentbox` in the container, so `~/.ssh/id_ed25519` → `/home/agentbox/.ssh/id_ed25519`. No copy is taken, so host-side changes are visible live. A line whose source is missing, or whose destination agentbox already uses, is reported and skipped |
| `ports` | one host port per line (1024-65535) | an in-container `socat` exposes each on container loopback `127.0.0.1:<port>` → `host.docker.internal:<port>`, so scripts using `127.0.0.1:<port>` reach the matching host service unchanged (socat binds as the unprivileged agentbox user, so a port below 1024 is rejected at start) |
| `setup.sh` | bash, run as agentbox | installs extra tools not in the shared image. Runs **once per container** and re-runs automatically when the script changes |
| `networks` | one docker network name per line | each network is attached to the container with `docker network connect` (an outer-daemon op, so it runs *after* the container is up, not as a `--network` flag) — letting the agent reach other containers on a shared network **by name**, with no host port published. Already-attached is a no-op; an unknown network is reported and skipped |
| `Dockerfile` | a Dockerfile `FROM agentbox:latest` | a CHILD image is built (root at build — so `apt-get install` works, unlike `setup.sh`) and run instead of the base. Self-contained: no cross-tier chaining, so a winning machine/project Dockerfile must restate anything it wants from a lower tier. Edit it, then `ab rebuild`. An empty file (only comments) is treated as absent — no child is built, the base image runs |

`ab config init [--machine] [--project] [file...]` does the two manual steps above (`mkdir -p`
the tier's directory, `cp` in the starter template) in one go — see
[Scoping config to a machine or a project](#scoping-config-to-a-machine-or-a-project) below for
the `--machine`/`--project` tier flags.

Example — reach a macOS guest whose SSH the host forwards at `127.0.0.1:2222`, install
`micro`, and copy in the SSH key a script needs to reach it:

```bash
ab config init env mounts ports setup.sh
# edit the four files it just wrote into ~/.config/agentbox/, then:
ab destroy && ab start     # pick up the new mount + flags
```

The `env` file supports both literal values and values imported from the host:

```env
# Stored in ~/.config/agentbox/env
MAC_HOST=host.docker.internal

# Imported from the host environment; the value is not written to this file
GITHUB_TOKEN
```

Export pass-through variables on the host before creating the container:

```bash
export GITHUB_TOKEN=...
ab destroy && ab start
```

Environment variables are available to the agent and processes inside the container. On each
command-executing `ab` invocation, only names declared in the resolved `env` file are overlaid from the
launching shell; this matters for dynamic values such as `STAY_SESSION_NAME`, which can differ
between stay sessions sharing one project container. Variables not currently set in the launching
shell retain the container's existing value.
They are not a secret boundary; use this syntax to keep values out of Agentbox config,
not to hide them from the agent or Docker.

Example — reach a database running as another container on the `lab` network, and install the
`psql` client to query it (no host port to publish; `psql` needs root at build, which `setup.sh`
can't provide — see `Dockerfile`):

```bash
ab config init networks Dockerfile
# edit the two files it just wrote, then build the child image (psql); networks attach on start
ab rebuild
# then, inside the container, reach the DB by its container name on the network:
ab bash
$ psql -h <db-container-name> -U <user> -d <db>
```

### Scoping config to a machine or a project

The six files above apply everywhere. To vary them, put a copy under `machines/<machine>/`,
`projects/<project-path>/`, or both — **each is resolved separately**, first match wins:

```
~/.config/agentbox/machines/<machine>/projects/<project-path>/env   # this project, this machine
~/.config/agentbox/machines/<machine>/env                           # this machine, any project
~/.config/agentbox/projects/<project-path>/env                      # this project, any machine
~/.config/agentbox/env                                              # everywhere (the plain file)
```

Getting one of these paths right by hand — especially the project one, with the leading `/`
dropped — is fiddly, so `ab config init [--machine] [--project] [file...]` builds it for you:
pass `--machine` and/or `--project` for however specific you want this override to be (neither
flag = the plain top-level row, both = the most specific one), and it creates that directory.
Any file names given after the flags are copied in as starter templates — an already-existing
file is reported and left alone, never overwritten:

```bash
ab config init                          # just the directory for row 4 above (~/.config/agentbox)
ab config init --project env            # row 3 + a starter `env` template
ab config init --machine --project setup.sh   # row 1 + a starter `setup.sh` template
```

`<machine>` is the host's name (`hostname`, or `AGENTBOX_MACHINE` to override the lookup
without changing the container's hostname). `<project-path>` is the project's absolute path
with the leading `/` dropped, so `/home/alice/myproj` becomes `home/alice/myproj`. `machines/`
and `projects/` are reserved directory names at the config root — without them a machine
called `home` would be indistinguishable from the first segment of `/home/alice/myproj`.

So on `myhost`, working in `~/myproj`, with this tree:

```
~/.config/agentbox/
├── env                                              # every project, every machine
├── setup.sh                                         # every project, every machine
├── machines/
│   └── myhost/
│       ├── ports                                    # only on myhost
│       └── projects/home/alice/myproj/
│           └── setup.sh                             # only myproj, only on myhost
└── projects/home/alice/myproj/
    └── env                                          # myproj, on any machine
```

`env` comes from `projects/home/alice/myproj/env`, `ports` from
`machines/myhost/ports`, `setup.sh` from
`machines/myhost/projects/home/alice/myproj/setup.sh`, and `mounts` is not configured at
all. `ab config` prints exactly this, without starting a container:

```bash
ab config
```

**Nothing to migrate.** The bare top-level files are the last tier, so an existing flat
`~/.config/agentbox/` keeps working unchanged — the scoped directories are purely additive.
This makes the directory worth version-controlling and sharing across machines.

**Confinement is preserved.** Port forwarding uses `--add-host=host.docker.internal:host-gateway`
(a `/etc/hosts` entry that grants the container **no** capability) plus an in-container `socat`
run as the unprivileged agentbox user — **not** `--network host`. The host's listening surface
is unchanged: the `socat` forwarders expose *only* the ports you declared on container loopback,
and `host.docker.internal` (added whenever `~/.config/agentbox/` exists) resolves to the host
gateway, so the agentbox user *can* also attempt a direct connection to other host ports —
bounded entirely by your host firewall, not by agentbox. A host service
must listen on an interface reachable from the docker bridge (`0.0.0.0` or the bridge IP), not
`127.0.0.1`-only.

**Host firewall (the common gotcha).** The container reaches declared services over the docker
bridge gateway, so the host firewall must also permit traffic *from the bridge* to each port.
If it doesn't, the symptom is a silent connect timeout — the forwarder accepts your connection
but the upstream never answers (`ab exec cat /var/log/agentbox-forward.log` shows the
`connect-timeout`). The tell: the host itself can still reach the service on `127.0.0.1:<port>`
while the container cannot. On NixOS, allow the declared ports from `docker0`:

```nix
networking.firewall.interfaces.docker0.allowedTCPPorts = [ 2222 ];
```

(Broader, simpler alternative: `networking.firewall.trustedInterfaces = [ "docker0" ];`.)

**Apply semantics:**
- `env` supplies the initial container environment at creation (`--env-file`), while its declared
  names are overlaid with current launching-shell values for each `ab` command. Editing the file
  still needs `ab destroy && ab start` to change the initial environment and the resolved file;
  per-session values such as `STAY_SESSION_NAME` do not require container recreation.
- `mounts` is established at container creation (bind mounts cannot be added to a running
  container) → editing it needs `ab destroy && ab start`.
- `ports` and `setup.sh` are read from the live mount → a plain `ab stop && ab start` picks up
  changes (`setup.sh` re-runs only if its content changed).
- `networks` is attached after the container is up (`docker network connect`, an outer-daemon
  op ab can't do from inside) → a plain `ab stop && ab start` picks up changes (no rebuild). It
  is skipped on the already-running early-return of `ab start`, so adding a network to a
  running container also needs `ab stop && ab start`.
- `Dockerfile` builds a child image → editing it needs `ab rebuild`. The child's cache key
  folds the base image tag + this Dockerfile's text, so a base rebuild OR a Dockerfile edit
  invalidates the cached child — but editing a `COPY`'d sibling WITHOUT touching the Dockerfile
  text does not, and also needs `ab rebuild` to re-bake. A plain `ab start` after an edit
  reuses the old child (`docker start` does not rebuild). An empty `Dockerfile` (only
  comments/blanks) is treated as absent — no child is built, the base image runs — so an empty
  `Dockerfile` at a specific tier opts that machine/project out of a less-specific one (absent
  == empty, the same property the other files already have).
- Which *tier* wins is decided at container creation (`ab` resolves the search and passes the
  chosen `ports`/`setup.sh` to the container) → adding a **more specific** file where a less
  specific one was already in effect needs `ab destroy && ab start`. Editing the contents of
  the file already in effect does not.
- Mounting a path (e.g. an SSH key) in is a deliberate trust grant: it is readable inside the
  confined container. The Sysbox confinement is unchanged; this only decides what the container
  may see.
- **`rw` is a larger grant, because it is bidirectional**: the agent can modify that host path,
  and whatever it writes there outlives `ab destroy`. This is why `ro` is the default and why
  agentbox's own `~/.config/agentbox` mount is read-only. Each `rw`
  line is reported by name at start, so a stray one is visible in `ab start`'s output.
- Enabling the directory on an already-created container needs `ab destroy && ab start` (the
  mount and `--add-host` / `--env-file` flags are set at create time).
- `mounts` line limits: paths containing spaces or commas are unsupported (whitespace separates
  the tokens; `,` separates `--mount` options), and a destination literally named `ro`/`rw`
  can't be expressed — a trailing `ro`/`rw` is always read as the mode.

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

## Tests

Two zero-dependency bash suites (no `bats` / `shellspec` needed):

- **`tests/run.sh`** — unit tests for the host-side pure logic: `bin/ab`'s `compute_names`
  (project → container/volume name; determinism + collision-distinctness), its
  `ab_config_candidates` / `ab_config_file` (the four-tier per-machine/per-project search —
  order, first-match-wins, and that each file resolves independently), its
  `ab_parse_mounts_line` / `ab_mount_dest_owner` (the `src [dst] [ro|rw]` grammar and
  duplicate-destination detection), grant option parsing and host-state preparation for the
  explicit GitHub/SSH credential grants (including persisted grant adoption for convenience
  auto-starts), and the entrypoint's `ab_parse_port_line` (ports-file parsing). It sources the
  scripts directly —
  they're written to be source-safe — so **no Docker** is needed:

  ```bash
  bash tests/run.sh
  ```

- **`tests/smoke.sh`** — integration test against a *running* project container: verifies
  the `~/.config/agentbox/` wiring end-to-end for the files actually resolved for this
  machine + project (env vars present, `setup.sh` tool installed, the `127.0.0.1:<port>`
  forward reaches the host service, each declared `mounts` line is bound with the right
  writability) and that confinement is unchanged
  (`Privileged=false`, `CapAdd=null`):

  ```bash
  ab start && bash tests/smoke.sh
  ```

## Notes

- `ab --version` prints agentbox's version (also shown in the `ab config` header). Versioning
  is patch-only for now — the tool is public but not yet released.
- The container user matches your host uid/gid, so files written to `/workspace` are
  owned by you on the host (no `root`-owned files, no git "dubious ownership" errors).
- The container's hostname matches the real host's (`--hostname "$(hostname)"`), so tools
  inside report the host's name rather than a container-ID hash.
- `ab exec`, `ab claude`, and `ab codex` run fine **without a TTY** (CI, pipes): `-t` is
  allocated only when stdin is a terminal, so `echo x | ab exec cat` and `ab exec make test`
  in CI just work (the old hardcoded `-it` crashed there with "the input device is not a
  TTY"). In every case the command runs under `~/.bashrc` — sourced via `BASH_ENV`, not an
  interactive shell — so the `claude()`/`codex()` permission-bypass wrappers apply even
  headless (`ab exec claude`/`ab codex` in CI still resolves to its permission-bypass
  wrapper, not the raw binary). `~/.bashrc` has no "if not interactive, return" guard, which
  is what makes this safe.
- Python is absent by design: `uv` provisions Python on demand. The Dockerfile guards this
  — the build **fails** if any transitive dependency pulls `python3` in. Per the global rule,
  always run Python via `uv run python`.
- Each CLI's binary is kept out of its bind-mounted config dir so the mount can't shadow it:
  **Claude Code** (a native glibc build) installs under `~/.local/bin`, separate from the
  mounted `~/.claude`; **Codex** (a static musl build) is relocated to `/usr/local/bin/codex`,
  separate from the mounted `~/.codex`.
- Both CLIs run with their safety guards **off** (wired in `~/.bashrc`) because agentbox
  itself is the sandbox (Sysbox confinement): Claude Code via `--dangerously-skip-permissions`,
  Codex via `--dangerously-bypass-approvals-and-sandbox`. The Codex flag is documented as
  "intended solely for running in environments that are externally sandboxed" — exactly
  agentbox — and it also keeps Codex from launching `bubblewrap`, which Sysbox blocks the
  `/proc` mount for anyway (so `bubblewrap` is deliberately not installed).

## License

MIT — see [LICENSE](./LICENSE).
