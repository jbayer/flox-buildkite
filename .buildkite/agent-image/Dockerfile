# Custom Buildkite hosted-agent image with Flox pre-installed.
#
# Why a custom image: baking Flox into the agent image means we never pay the
# install cost per build (the equivalent of flox/install-flox-action on GitHub).
# Warming the Nix store across builds is handled separately by a cache volume on
# /nix (see .buildkite/pipeline.yml).
#
# Registration (recommended path): Agents -> your cluster -> Agent Images ->
# New Image. Paste this file MINUS the `FROM` line below -- the UI pre-fills and
# locks `FROM` to buildkite/hosted-agent-base for the queue's architecture. Then
# attach the image to the queue under: Queues -> queue -> Base image -> Agent image.
#
# Arch: auto-detected via `uname -m` at build time (x86_64 or aarch64), so the
# same Dockerfile works unchanged on amd64 or arm64 queues -- no edits needed.

FROM buildkite/hosted-agent-base:latest

ENV DEBIAN_FRONTEND=noninteractive

# Flox installer prerequisites. The base image already carries git/ca-certificates,
# which the buildkite-agent itself requires; listed here explicitly for clarity.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        sudo \
        xz-utils \
        openssh-client \
        git \
    && rm -rf /var/lib/apt/lists/*

# Install Flox. The .deb bundles its own Nix, so there is no separate Nix install.
# - `uname -m` gives x86_64 / aarch64, which matches Flox's .deb URL naming, so
#   the image builds correctly on either architecture with no edits.
# - install via `apt-get install ./flox.deb` (not `dpkg -i`) so apt resolves any
#   dependencies in one step.
ARG FLOX_VERSION=1.12.1
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL "https://downloads.flox.dev/by-env/stable/deb/flox-${FLOX_VERSION}.${arch}-linux.deb" \
        -o /tmp/flox.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/flox.deb; \
    rm -rf /tmp/flox.deb /var/lib/apt/lists/*

# Single-user mode: bypass the nix-daemon. There is no systemd as PID 1 in the
# agent container, so Nix operates on the store directly as the job's user.
# This is the key line that makes Flox work in a container.
ENV NIX_REMOTE=auto

# Buildkite hosted agents choose the job's runtime user and forbid changing
# USER / UID / GID in the Dockerfile, so we cannot chown /nix to a user we make.
# Instead make the store traversable and writable by whatever user runs the job,
# so `flox activate` can add store paths at runtime.
RUN chmod -R a+rwX /nix

# Fail the image build early if anything above is broken.
RUN flox --version
