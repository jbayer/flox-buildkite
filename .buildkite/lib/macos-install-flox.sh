#!/usr/bin/env bash
# Install Flox from its macOS .pkg, then activate the repo env and run the
# sentinel. Used by .buildkite/pipeline.macos.yml.
#
# Why a script file instead of an inline `command: |` block: on the macOS hosted
# agent, shell state does NOT carry across the lines of an inline command -- a
# variable set on one line is empty on the next. (That left `curl -o "$PKG"` with
# a blank argument.) Running everything as one
# `bash .buildkite/lib/macos-install-flox.sh` invocation makes it a single real
# shell, so the PKG variable and `set -euo pipefail` behave normally.
set -euo pipefail

: "${FLOX_VERSION:?set FLOX_VERSION in the pipeline env}"

PKG="/tmp/flox-cache/flox-${FLOX_VERSION}.aarch64-darwin.pkg"
URL="https://downloads.flox.dev/by-env/stable/osx/flox-${FLOX_VERSION}.aarch64-darwin.pkg"

echo "--- the .pkg install needs root -- check passwordless sudo first"
if ! sudo -n true 2>/dev/null; then
  echo "NO passwordless sudo on this queue. The Flox .pkg cannot create the"
  echo "/nix APFS volume + nix-daemon without it. See README (macOS section)."
  exit 1
fi

if [ -f "$PKG" ]; then
  echo "--- reuse cached .pkg ($PKG)"
else
  echo "--- download Flox ${FLOX_VERSION} .pkg (cold; cached for next build)"
  mkdir -p "$(dirname "$PKG")"
  curl -fsSL -o "$PKG" "$URL"
fi

echo "--- install Flox (creates /nix APFS volume + nix-daemon; needs root)"
sudo installer -pkg "$PKG" -target /

echo "--- put flox on PATH"
# The .pkg installs the flox binary under /usr/local/bin. flox is self-contained:
# it does not need a sourced Nix daemon profile (verified on macos-medium).
export PATH="/usr/local/bin:$PATH"
if ! command -v flox >/dev/null 2>&1; then
  echo "flox not on PATH after install; looked in /usr/local/bin:"
  ls -l /usr/local/bin/flox 2>/dev/null || echo "  (no /usr/local/bin/flox)"
  exit 1
fi
flox --version

echo "--- activate the repo env and run the sentinel"
# Requires aarch64-darwin in .flox/env/manifest.toml [options] systems.
time flox activate -- hello
