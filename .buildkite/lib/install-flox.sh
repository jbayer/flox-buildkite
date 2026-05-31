#!/usr/bin/env bash
# Tier 0: install Flox per build on a generic Linux Buildkite agent -- no custom
# agent image required. The Flox .deb bundles its own Nix, so this is all you
# need to run `flox activate` on any Linux hosted/self-hosted queue.
#
# Idempotent: if flox is already on PATH (a custom agent image, or a warm /nix
# cache volume already provides it) this is a fast no-op. So it's safe to leave
# at the top of every step even after you move to a custom image (Tier 1).
#
# Needs root (hosted Linux agents run as root) or passwordless sudo. Pin
# FLOX_VERSION in the pipeline env for reproducibility.
set -euo pipefail
: "${FLOX_VERSION:=1.12.1}"

if command -v flox >/dev/null 2>&1; then
  echo "--- Flox already installed ($(flox --version)); skipping install"
  exit 0
fi

SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
arch="$(uname -m)"   # x86_64 / aarch64 -- matches the .deb naming
url="https://downloads.flox.dev/by-env/stable/deb/flox-${FLOX_VERSION}.${arch}-linux.deb"

echo "--- installing Flox ${FLOX_VERSION} (.deb bundles Nix) [timed]"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp/flox.deb"
$SUDO apt-get update -qq
# `apt-get install ./flox.deb` (not dpkg -i) so deps resolve in one step.
$SUDO apt-get install -y --no-install-recommends "$tmp/flox.deb"

# Single-user Nix: operate on the store directly as the job user (no daemon).
# Make /nix writable in case the job user isn't the store owner.
$SUDO chmod -R a+rwX /nix 2>/dev/null || true

flox --version
echo "--- Flox installed. (Set NIX_REMOTE=auto in the pipeline env for single-user mode.)"
