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
# Fast-install archive (zstd), keyed by version, on the persistent cache volume.
FAST_ARCHIVE="/tmp/flox-cache/nix-store-${FLOX_VERSION}.tar.zst"

# The .pkg installs flox under /usr/local/bin.
export PATH="/usr/local/bin:$PATH"

# The normal multi-user .pkg install (~42s; the floor without the fast path).
pkg_install() {
  echo "--- installing Flox from the .pkg (multi-user)"
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
  echo "--- install Flox (creates /nix APFS volume + nix-daemon; needs root) [timed]"
  time sudo installer -pkg "$PKG" -target /
  export PATH="/usr/local/bin:$PATH"
  if ! command -v flox >/dev/null 2>&1; then
    echo "flox not on PATH after install; looked in /usr/local/bin:"
    ls -l /usr/local/bin/flox 2>/dev/null || echo "  (no /usr/local/bin/flox)"
    exit 1
  fi
  flox --version
}

# EXPERIMENTAL fast install (opt-in FAST_INSTALL=1). Restores /nix from a zstd
# archive (~1s) instead of the .pkg's ~25s xz extraction, running Nix SINGLE-USER
# (no daemon) like the Linux flow. When SINGLE_USER_NIX is set, the S3 read uses
# the job's own creds, so the macOS daemon-auth step below is skipped.
# FAST install is ON by default (~2s vs ~42s); set FAST_INSTALL=0 to force the
# stock .pkg. If the fast path ever fails (a future macOS change), it cleans up
# the partial /nix and falls back to the .pkg, so a build can't be broken by it.
FAST_INSTALL="${FAST_INSTALL:-1}"
SINGLE_USER_NIX=""
if [ "$FAST_INSTALL" = "1" ] && [ -f "$FAST_ARCHIVE" ]; then
  echo "--- FAST install: restoring single-user Nix from $FAST_ARCHIVE"
  if bash .buildkite/lib/macos-fast-install.sh "$FAST_ARCHIVE"; then
    SINGLE_USER_NIX=1
    export NIX_REMOTE=auto
    export PATH="/usr/local/bin:$PATH"
    echo "--- FAST install OK (single-user Nix; no daemon) -- ~2s vs ~42s"
  else
    echo "WARNING: fast install failed; cleaning up partial /nix and falling back to the .pkg" >&2
    bash .buildkite/lib/macos-fast-install.sh --cleanup || true
    pkg_install
  fi
else
  # No cached archive yet (or FAST_INSTALL=0): stock .pkg. When fast is enabled,
  # bootstrap the zstd archive so the NEXT build on this cache volume is fast.
  pkg_install
  if [ "$FAST_INSTALL" = "1" ]; then
    echo "--- bootstrap: caching /nix as zstd for future fast installs"
    bash .buildkite/lib/macos-fast-install.sh --bootstrap "$FAST_ARCHIVE" \
      || echo "WARNING: fast-install bootstrap archive failed (non-fatal)"
  fi
fi

# One-time MEASUREMENT (opt-in via MEASURE_NIX_RESTORE=1): how fast could a
# cache-and-restore installer be vs the ~42s `installer -pkg`? Non-fatal; only
# runs when explicitly requested, so normal builds are untouched.
if [ -n "${MEASURE_NIX_RESTORE:-}" ]; then
  bash .buildkite/lib/diagnostics/macos-measure-nix-restore.sh \
    || echo "WARNING: nix-restore measurement failed (non-fatal)"
fi

# Diagnostic (opt-in MEASURE_PKG_BREAKDOWN=1): build 13 showed the store payload
# is ~1s, so the ~40s install is scaffolding -- this finds what. Non-fatal.
if [ -n "${MEASURE_PKG_BREAKDOWN:-}" ]; then
  bash .buildkite/lib/diagnostics/macos-pkg-breakdown.sh \
    || echo "WARNING: pkg breakdown failed (non-fatal)"
fi

# --- S3 binary cache (optional; layer-2 read + write-back) ----------------------
# macOS is multi-user Nix, so reads go through the root daemon -- see
# macos-s3-daemon-auth.sh. The read setup is made NON-FATAL: a macOS quirk falls
# back to upstream (slower) instead of breaking the build. flox hides the
# substituter source, so the clearest proof the cache is wired is the WRITE-BACK
# (`+++ pushing ... to s3://...` / `--- push complete`) at the end of this step.
#
# Put `nix` on PATH for the cache scripts (flox bundles nix, but the .pkg's nix
# CLI lives in the multi-user profile, not necessarily on the job PATH).
if ! command -v nix >/dev/null 2>&1; then
  for d in /nix/var/nix/profiles/default/bin /run/current-system/sw/bin /usr/local/bin; do
    if [ -x "$d/nix" ]; then export PATH="$d:$PATH"; break; fi
  done
fi
# Single-user fast install may not have the default-profile symlink on PATH; find
# the nix binary directly in the store as a last resort.
if ! command -v nix >/dev/null 2>&1; then
  nixbin="$(ls -1 /nix/store/*/bin/nix 2>/dev/null | head -1)"
  [ -n "$nixbin" ] && export PATH="$(dirname "$nixbin"):$PATH"
fi
echo "--- nix on PATH: $(command -v nix || echo 'NOT FOUND')"
# macOS: Nix's curl uses OpenSSL, which has NO default CA bundle here, so
# client-side TLS (`nix copy` to/from the S3 cache) fails with curlCode 60
# ("unable to get local issuer certificate"). Point it at a CA bundle. (The
# nix-daemon already has this via its launchd plist; this is for the job's own
# nix client -- the push and any client read.) Linux finds its CA automatically.
if [ -z "${NIX_SSL_CERT_FILE:-}" ]; then
  for ca in \
    /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt \
    /etc/ssl/cert.pem \
    "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt"; do
    if [ -f "$ca" ]; then export NIX_SSL_CERT_FILE="$ca"; break; fi
  done
  if [ -n "${NIX_SSL_CERT_FILE:-}" ]; then
    echo "--- client CA bundle: NIX_SSL_CERT_FILE=$NIX_SSL_CERT_FILE"
  else
    echo "WARNING: no CA bundle found; client S3 TLS (push) may fail with curlCode 60"
  fi
fi
# Load cache secrets into the env (no-op if S3_CACHE_BUCKET empty). `source` so
# the creds persist into the daemon-auth, activate, and push below.
source .buildkite/lib/s3-cache-load-secrets.sh
# Read path: substituter -> /etc/nix/nix.conf, then give the daemon creds + reload.
bash .buildkite/lib/s3-cache-configure.sh \
  || echo "WARNING: s3-cache-configure failed; reads may fall back to upstream"
# Multi-user only: the root daemon needs the S3 creds + a reload. Single-user
# (fast install) uses the job's own creds directly, like Linux -- skip it.
if [ -n "$SINGLE_USER_NIX" ]; then
  echo "--- single-user Nix: skipping macOS daemon-auth (job creds used directly)"
else
  bash .buildkite/lib/macos-s3-daemon-auth.sh \
    || echo "WARNING: macos-s3-daemon-auth failed; reads may fall back to upstream"
fi

echo "--- activate the repo env and run the sentinel"
# Requires aarch64-darwin in .flox/env/manifest.toml [options] systems.
# Cold/miss: the daemon substitutes the closure from the S3 cache, then upstream.
time flox activate -- hello

# Write back this build's closure (client-side; uses the job's S3 token) so future
# cold builds pull it from the cache. Non-fatal so a push hiccup can't fail the build.
bash .buildkite/lib/s3-cache-push.sh \
  || echo "WARNING: s3-cache-push failed; cache not updated this build"

# Read-proof: pull that just-pushed closure back FROM the cache with signatures
# required -- a deterministic confirmation reads work. It pulls THIS build's
# closure, so it only makes sense when we pushed it; gate it on write-back being
# enabled (S3_CACHE_PUSH=1). Non-fatal.
if [ "${S3_CACHE_PUSH:-0}" = "1" ]; then
  bash .buildkite/lib/s3-cache-read-proof.sh \
    || echo "WARNING: s3-cache-read-proof failed; reads from the cache may not be working"
fi
