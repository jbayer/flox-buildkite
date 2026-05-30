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

# --- S3 binary cache (optional; layer-2 read + write-back) ----------------------
# macOS is multi-user Nix, so reads go through the root daemon -- see
# macos-s3-daemon-auth.sh. The read setup is made NON-FATAL: a macOS quirk falls
# back to upstream (slower) instead of breaking the build. Watch the activate log
# for "from 's3://...'" to confirm the daemon actually used the cache.
#
# Put `nix` on PATH for the cache scripts (flox bundles nix, but the .pkg's nix
# CLI lives in the multi-user profile, not necessarily on the job PATH).
if ! command -v nix >/dev/null 2>&1; then
  for d in /nix/var/nix/profiles/default/bin /run/current-system/sw/bin; do
    if [ -x "$d/nix" ]; then export PATH="$d:$PATH"; break; fi
  done
fi
# Load cache secrets into the env (no-op if S3_CACHE_BUCKET empty). `source` so
# the creds persist into the daemon-auth, activate, and push below.
source .buildkite/lib/s3-cache-load-secrets.sh
# Read path: substituter -> /etc/nix/nix.conf, then give the daemon creds + reload.
bash .buildkite/lib/s3-cache-configure.sh \
  || echo "WARNING: s3-cache-configure failed; reads may fall back to upstream"
bash .buildkite/lib/macos-s3-daemon-auth.sh \
  || echo "WARNING: macos-s3-daemon-auth failed; reads may fall back to upstream"

echo "--- activate the repo env and run the sentinel"
# Requires aarch64-darwin in .flox/env/manifest.toml [options] systems.
# Cold/miss: the daemon substitutes the closure from the S3 cache, then upstream.
time flox activate -- hello

# Write back this build's closure (client-side; uses the job's S3 token) so future
# cold builds pull it from the cache. Non-fatal so a push hiccup can't fail the build.
bash .buildkite/lib/s3-cache-push.sh \
  || echo "WARNING: s3-cache-push failed; cache not updated this build"
