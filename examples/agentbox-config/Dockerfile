# ~/.config/agentbox/Dockerfile — a CHILD image that layers tools onto the base,
# FROM the base tag supplied by ab. This is the place for tools that need ROOT at BUILD time
# (`apt-get install`), keeping the base image lean and tool-free.
#
# Unlike setup.sh (which runs as the unprivileged agentbox user and so CAN'T apt-get install —
# it has no root), a Dockerfile build runs as root, so packaged tools are fair game here.
#
# IMPORTANT — do NOT end this Dockerfile with `USER agentbox`. The base image's default USER is
# root, and it must STAY root: agentbox's entrypoint runs as PID 1 and starts the inner dockerd
# and chowns its socket, which need root. (ab runs your interactive `ab bash` / `ab exec` /
# `ab claude` sessions as the unprivileged agentbox user via `docker exec --user agentbox` —
# that is where the confinement lives, not in the image USER.) So install as root and leave the
# image as root.
#
# Self-contained: this is the WHOLE image, not a fragment. There is NO cross-tier chaining — a
# machine/project Dockerfile that wins the search must restate anything it wants from a lower
# tier (e.g. the psql install below). First match wins, same as the other config files.
#
# Build context is THIS FILE's directory (its dirname), so COPY pulls siblings from alongside
# it (e.g. a config file dropped next to this Dockerfile).
#
# Apply: build + recreate is `ab rebuild`. The child's cache key folds the base image tag + this
# Dockerfile's text, so EITHER a base rebuild OR an edit here invalidates the cached child.
# CAVEAT: editing a COPY'd SIBLING without touching this Dockerfile's text leaves the key
# unchanged — run `ab rebuild` to re-bake. (A plain `ab start` after an edit reuses the old
# child image: `docker start` does not rebuild, so the change wouldn't take until `ab rebuild`.)
ARG AGENTBOX_BASE_IMAGE=agentbox:latest
FROM ${AGENTBOX_BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Example: the psql client (v17, from the PostgreSQL upstream PGDG repo — pinned here
# regardless of whichever version the distro's postgresql-client happens to track on this
# base, Ubuntu 26.04), so the agent can reach a database on a shared docker network (see
# `networks`). Installed as root at BUILD time — setup.sh can't, it has no root. Supply
# your own connection when you connect; no credentials live here.
# The child preserves the base entrypoint's rootful startup contract. This is an intentional,
# human-authorized DL3002 exception; ab runs command sessions as agentbox explicitly.
# hadolint ignore=DL3002
USER 0
RUN apt-get update \
 && apt_version() { apt-cache policy "$1" | sed -n 's/^  Candidate: //p'; } \
 && apt-get install -y --no-install-recommends \
      "curl=$(apt_version curl)" "ca-certificates=$(apt_version ca-certificates)" \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc \
 && pgdg_codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $pgdg_codename-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "postgresql-client-17=$(apt_version postgresql-client-17)" \
 && rm -rf /var/lib/apt/lists/*
