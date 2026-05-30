#!/usr/bin/env bash
# READ path: make Flox/Nix substitute store paths from the R2 binary cache.
#
# Flox shells out to its own bundled Nix, which reads /etc/nix/nix.conf. This
# script idempotently appends the R2 substituter + the cache's trusted public
# key to that file, so a cold `flox activate` pulls already-built paths from R2
# instead of re-downloading them from upstream.
#
# All inputs here are NON-SECRET (bucket, account id, public key), so you can
# equivalently bake these two lines into the agent image at build time -- see
# .buildkite/agent-image/Dockerfile (the reliable Phase-1 path). This runtime
# script exists so the demo pipeline and self-hosted agents work without
# rebuilding the image.
#
# Required env (non-secret):
#   R2_BUCKET             e.g. flox-binary-cache
#   R2_ACCOUNT_ID         the hex id in your R2 S3 endpoint host
#   R2_CACHE_PUBLIC_KEY   e.g. flox-binary-cache-1:base64=
#
# Authenticating READS of a PRIVATE bucket additionally needs the R2 API token
# in the job environment as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. (Or make
# the bucket public-read and point R2_* at an https:// URL instead -- see README.)
set -euo pipefail

: "${R2_BUCKET:?set R2_BUCKET}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"
: "${R2_CACHE_PUBLIC_KEY:?set R2_CACHE_PUBLIC_KEY}"

CONF=/etc/nix/nix.conf
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
SUBSTITUTER="s3://${R2_BUCKET}?endpoint=${ENDPOINT}&region=auto"
MARKER="flox-binary-cache R2"

# Append a line to nix.conf, using sudo only if the file isn't already writable
# (hosted agents run as root; self-hosted/local may not).
append() {
  if [ -w "$CONF" ]; then printf '%s\n' "$1" >>"$CONF"
  else printf '%s\n' "$1" | sudo tee -a "$CONF" >/dev/null; fi
}

if grep -qF "$MARKER" "$CONF" 2>/dev/null; then
  echo "--- R2 substituter already configured in $CONF (no-op)"
else
  echo "+++ adding R2 substituter to $CONF"
  append ""
  append "# --- ${MARKER} (CloudFlare) ----------------------------------------"
  append "extra-substituters = ${SUBSTITUTER}"
  append "extra-trusted-public-keys = ${R2_CACHE_PUBLIC_KEY}"
fi

echo "--- effective substituters / trusted keys"
# &profile/secret bits are config detail; trim the query string for readability.
nix --extra-experimental-features 'nix-command' config show 2>/dev/null \
  | grep -E '^(substituters|trusted-public-keys) ' \
  | sed 's#\?endpoint=[^ ]*##'
