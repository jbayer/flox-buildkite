# Custom Buildkite hosted-agent image with Flox pre-installed.
#
# Why a custom image: baking Flox into the agent image means we never pay the
# install cost per build (the equivalent of flox/install-flox-action on GitHub).
# Warming the Nix store across builds is handled separately by a cache volume on
# /nix (see .buildkite/pipeline.yml).
#
# Common packages (language runtimes, compilers, toolchains) can be baked into the
# store at build time via the SEED_PACKAGES arg below, so they are present even on
# a cold cache volume.
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

# Fail the image build early if Flox installed correctly.
RUN flox --version

# --- Optional: bake the S3 binary-cache READ path into the image ----------------
# Works with any S3-compatible cache (AWS S3, CloudFlare R2, MinIO, Ceph, …). The
# substituter pointer is NON-SECRET (bucket, endpoint, region, public key), so it
# can live in the image as reliable Phase-1 config -- present on every build with
# no runtime step. When S3_CACHE_BUCKET is set, write the substituter + trusted
# key into /etc/nix/nix.conf (the file Flox's bundled Nix reads). Empty = skip.
#
# Like SEED_PACKAGES, the Buildkite UI image editor builds this Dockerfile as-is
# (no --build-arg), so to enable baking you edit these ARG defaults. The runtime
# alternative that needs no image rebuild is .buildkite/lib/s3-cache-configure.sh,
# used by .buildkite/pipeline.s3-cache.yml.
#
# S3_CACHE_ENDPOINT is the full endpoint URL, e.g.
#   CloudFlare R2: https://<ACCOUNT_ID>.r2.cloudflarestorage.com  (region auto)
#   AWS S3:        https://s3.us-east-1.amazonaws.com             (region us-east-1)
#
# Authenticating READS of a PRIVATE bucket still needs the S3 access key in the
# job environment at runtime (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY); only the
# non-secret pointer is baked here. WRITE-back is always a runtime step -- see
# .buildkite/lib/s3-cache-push.sh.
ARG S3_CACHE_BUCKET=""
ARG S3_CACHE_ENDPOINT=""
ARG S3_CACHE_REGION="auto"
ARG S3_CACHE_PUBLIC_KEY=""
RUN set -eux; \
    if [ -n "$S3_CACHE_BUCKET" ]; then \
        { \
          echo ""; \
          echo "# --- flox S3 binary cache ---"; \
          echo "extra-substituters = s3://${S3_CACHE_BUCKET}?endpoint=${S3_CACHE_ENDPOINT}&region=${S3_CACHE_REGION}"; \
          echo "extra-trusted-public-keys = ${S3_CACHE_PUBLIC_KEY}"; \
        } >>/etc/nix/nix.conf; \
        echo "baked S3 cache substituter into /etc/nix/nix.conf"; \
    fi

# --- Configurable seed packages -------------------------------------------------
# Packages baked into the Nix store at build time so they live in the seed
# (/opt/nix-seed) and are therefore present in /nix even on a COLD cache volume.
# Put common, heavy, slow-to-download things here (language runtimes, compilers,
# toolchains) so cold builds don't re-download them.
#
# Pluggable: edit the SEED_PACKAGES default below -- a space-separated list of
# Flox pkg-paths. The Buildkite UI image editor builds the Dockerfile as-is (no
# --build-arg), so the default value is what's used. Examples:
#     ARG SEED_PACKAGES="nodejs python3 go"
#     ARG SEED_PACKAGES="nodejs@20 rustc cargo gcc"
# Set to "" to bake nothing beyond Flox itself.
#
# Caveat: a baked package only yields a runtime cache hit when a project env
# resolves to the SAME store path (same version, same catalog). Bake the
# versions your projects actually use.
#
# `hello` mirrors the CI smoke-test sentinel in .flox/env/manifest.toml so the
# pipeline's `flox activate -- hello` is warm. It is an OPTIMIZATION ONLY: this
# seed never decides what `flox activate` exposes (the repo manifest does). If
# this list drifts from the manifest, the sentinel is merely pulled cold
# (slower) on first activate -- it is never missing.
ARG SEED_PACKAGES="hello"
RUN set -eux; \
    if [ -n "$SEED_PACKAGES" ]; then \
        mkdir -p /opt/seed-env; \
        cd /opt/seed-env; \
        flox init; \
        flox install $SEED_PACKAGES; \
        flox list; \
    fi

# Make the store traversable/writable by whatever user the agent runs jobs as.
# Buildkite forbids changing USER/UID/GID, so we cannot chown to a user we make.
# Done after seeding packages so their store paths get the same permissions.
RUN chmod -R a+rwX /nix

# Stash the baked Nix store outside /nix so a /nix cache volume (empty on the
# first build) can be seeded from it at runtime -- see .buildkite/lib/ensure-nix.sh.
# Hardlink the copy (-l) so it costs ~no extra image space; fall back to a real
# copy if hardlinks aren't possible. /opt is not shadowed by the /nix volume.
RUN cp -al /nix /opt/nix-seed || cp -a /nix /opt/nix-seed
