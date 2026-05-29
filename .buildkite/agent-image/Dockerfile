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
# Arch: the UI editor builds the Dockerfile as-is (no --build-arg), so the
# FLOX_ARCH *default* below is what gets used. It defaults to aarch64 (arm64
# queue); change the default to x86_64 for an amd64 queue. When building this
# file locally/in a registry with the FROM line, you can instead pass
# `--build-arg FLOX_ARCH=x86_64`.

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
ARG FLOX_VERSION=1.12.1
ARG FLOX_ARCH=aarch64
RUN curl -fsSL "https://downloads.flox.dev/by-env/stable/deb/flox-${FLOX_VERSION}.${FLOX_ARCH}-linux.deb" \
        -o /tmp/flox.deb \
    && dpkg -i /tmp/flox.deb \
    && rm /tmp/flox.deb

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
