# Self-hosted Buildkite agent with Flox preinstalled.
#
# Unlike Buildkite *hosted* agents, a self-hosted agent runs on infrastructure you
# control, so /nix can persist reliably. Run this as a long-lived container with a
# Docker named volume mounted at /nix (see docker-compose.yml):
#
#   * Docker populates the empty named volume from the image's baked /nix on first
#     run, so Flox works immediately (no shadowing, no seed needed).
#   * The volume then persists the store across builds AND container restarts ->
#     a reliably warm cache, with none of the best-effort locality of hosted
#     cache volumes.
#
# Same Flox-in-a-container mechanics as the hosted image: single-user Nix via
# NIX_REMOTE=auto, arch auto-detected, and the same SEED_PACKAGES knob.
FROM buildkite/agent:3-ubuntu-22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        sudo \
        xz-utils \
        openssh-client \
        git \
    && rm -rf /var/lib/apt/lists/*

# Install Flox (.deb bundles its own Nix). Arch auto-detected via uname -m.
ARG FLOX_VERSION=1.12.1
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL "https://downloads.flox.dev/by-env/stable/deb/flox-${FLOX_VERSION}.${arch}-linux.deb" \
        -o /tmp/flox.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/flox.deb; \
    rm -rf /tmp/flox.deb /var/lib/apt/lists/*

# Single-user mode: no systemd / nix-daemon in the container.
ENV NIX_REMOTE=auto

RUN flox --version

# Bake common packages into the store (same knob as the hosted image). With a
# persistent /nix volume these are present reliably on every build.
#
# `hello` mirrors the CI smoke-test sentinel in .flox/env/manifest.toml so the
# pipeline's `flox activate -- hello` is warm. OPTIMIZATION ONLY: this seed never
# decides what `flox activate` exposes (the repo manifest does). If this drifts
# from the manifest, the sentinel is just pulled cold once, never missing.
ARG SEED_PACKAGES="hello"
RUN set -eux; \
    if [ -n "$SEED_PACKAGES" ]; then \
        mkdir -p /opt/seed-env; \
        cd /opt/seed-env; \
        flox init; \
        flox install $SEED_PACKAGES; \
        flox list; \
    fi

RUN chmod -R a+rwX /nix

# Let the job user append the S3-cache substituter to /etc/nix/nix.conf at runtime
# (.buildkite/lib/s3-cache-configure.sh) without sudo, in case the agent runs jobs
# as a non-root user. nix.conf lives in the image (not the /nix volume), so this
# resets per container start; the configure script re-applies it idempotently.
RUN chmod a+rw /etc/nix/nix.conf

# Seed stash for parity with the hosted image. Not needed when /nix is a Docker
# named volume (Docker auto-populates it from the image), but it lets the same
# .buildkite/lib/ensure-nix.sh self-heal if you ever mount an empty bind mount.
RUN cp -al /nix /opt/nix-seed || cp -a /nix /opt/nix-seed
