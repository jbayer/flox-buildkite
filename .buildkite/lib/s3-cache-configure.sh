#!/usr/bin/env bash
# READ path: make Flox/Nix substitute store paths from an S3-compatible binary
# cache (any provider: AWS S3, CloudFlare R2, MinIO, Ceph RGW, Backblaze B2, …).
#
# Flox shells out to its own bundled Nix, which reads /etc/nix/nix.conf. This
# script idempotently appends the cache's substituter + trusted public key to
# that file, so a cold `flox activate` pulls already-built paths from the cache
# instead of re-downloading them from upstream.
#
# All inputs here are NON-SECRET (bucket, endpoint, region, public key), so you
# can equivalently bake these two lines into the agent image at build time -- see
# .buildkite/agent-image/Dockerfile (the reliable Phase-1 path). This runtime
# script exists so the demo pipeline and self-hosted agents work without
# rebuilding the image.
#
# Required env (non-secret):
#   S3_CACHE_BUCKET       e.g. flox-binary-cache
#   S3_CACHE_ENDPOINT     full S3 endpoint URL for your provider, e.g.
#                           CloudFlare R2: https://<ACCOUNT_ID>.r2.cloudflarestorage.com
#                           AWS S3:        https://s3.us-east-1.amazonaws.com
#                           MinIO:         https://minio.example.com:9000
# Optional env:
#   S3_CACHE_REGION       defaults to "auto" (correct for R2); AWS users set a
#                         real region (e.g. us-east-1); MinIO typically us-east-1.
#   S3_CACHE_PUBLIC_KEY   e.g. flox-binary-cache-1:base64=   (required)
#
# Authenticating READS of a PRIVATE bucket additionally needs the access key in
# the job environment as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. (Or make the
# bucket public-read and point at an https:// URL instead -- see README.)
set -euo pipefail

: "${S3_CACHE_BUCKET:?set S3_CACHE_BUCKET}"
: "${S3_CACHE_ENDPOINT:?set S3_CACHE_ENDPOINT (full S3 endpoint URL)}"
: "${S3_CACHE_PUBLIC_KEY:?set S3_CACHE_PUBLIC_KEY}"

CONF=/etc/nix/nix.conf
SUBSTITUTER="s3://${S3_CACHE_BUCKET}?endpoint=${S3_CACHE_ENDPOINT}&region=${S3_CACHE_REGION:-auto}"
MARKER="flox S3 binary cache"

# Append a line to nix.conf, using sudo only if the file isn't already writable
# (hosted agents run as root; self-hosted/local may not).
append() {
  if [ -w "$CONF" ]; then printf '%s\n' "$1" >>"$CONF"
  else printf '%s\n' "$1" | sudo tee -a "$CONF" >/dev/null; fi
}

if grep -qF "$MARKER" "$CONF" 2>/dev/null; then
  echo "--- S3 cache substituter already configured in $CONF (no-op)"
else
  echo "+++ adding S3 cache substituter to $CONF"
  append ""
  append "# --- ${MARKER} -------------------------------------------------------"
  append "extra-substituters = ${SUBSTITUTER}"
  append "extra-trusted-public-keys = ${S3_CACHE_PUBLIC_KEY}"
fi

echo "--- effective substituters / trusted keys"
# the ?endpoint=… query string is config detail; trim it for readability.
nix --extra-experimental-features 'nix-command' config show 2>/dev/null \
  | grep -E '^(substituters|trusted-public-keys) ' \
  | sed 's#\?endpoint=[^ ]*##'
