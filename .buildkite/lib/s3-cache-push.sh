#!/usr/bin/env bash
# WRITE path: push (write back) Nix store paths to an S3-compatible binary cache,
# SIGNED, so future COLD builds substitute them from the cache instead of
# re-downloading from upstream. Counterpart to s3-cache-configure.sh (the read
# path). Works with any S3-compatible provider (AWS S3, R2, MinIO, Ceph, …).
#
# By default it pushes the closure of the ACTIVATED repo environment ($FLOX_ENV)
# -- i.e. the env plus every package `flox activate` realized, which is exactly
# what a cold build needs warm. Pass explicit /nix/store/... paths as arguments
# to push something else instead.
#
# Required env (non-secret):
#   S3_CACHE_BUCKET       e.g. flox-binary-cache
#   S3_CACHE_ENDPOINT     full S3 endpoint URL (see s3-cache-configure.sh)
# Optional env:
#   S3_CACHE_REGION       defaults to "auto" (R2); set a real region for AWS S3.
#
# Required env (SECRET -- inject at runtime, e.g. via Buildkite cluster secrets;
# never bake these into the image):
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   the cache's S3 access key
#   S3_CACHE_SIGNING_KEY                         the Nix secret signing key TEXT
#     (or set S3_CACHE_SIGNING_KEY_FILE to a path holding the key instead)
#
# The signing key is the one credential that must be guarded: anyone holding it
# can place trusted paths in your cache. This script writes it to a 0600 temp
# file, uses it, and deletes it on exit; it is never echoed.
set -euo pipefail

# Graceful opt-out: empty/unset S3_CACHE_BUCKET means "no S3 cache" -- skip the
# write-back so the standard pipeline still works without one.
if [ -z "${S3_CACHE_BUCKET:-}" ]; then
  echo "--- S3 cache not configured (S3_CACHE_BUCKET empty); skipping write-back"
  exit 0
fi
: "${S3_CACHE_ENDPOINT:?set S3_CACHE_ENDPOINT (full S3 endpoint URL)}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID (S3 access key id)}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY (S3 secret access key)}"

# aws-sdk otherwise probes the (absent) instance-metadata endpoint and stalls.
export AWS_EC2_METADATA_DISABLED=true

# Resolve the signing key into a private temp file; clean it up on exit.
keyfile="${S3_CACHE_SIGNING_KEY_FILE:-}"
tmpkey=""
if [ -z "$keyfile" ]; then
  : "${S3_CACHE_SIGNING_KEY:?set S3_CACHE_SIGNING_KEY or S3_CACHE_SIGNING_KEY_FILE}"
  tmpkey="$(mktemp)"
  keyfile="$tmpkey"
  ( umask 177; printf '%s' "$S3_CACHE_SIGNING_KEY" >"$keyfile" )
fi
cleanup() { [ -n "$tmpkey" ] && rm -f "$tmpkey"; return 0; }
trap cleanup EXIT

S3="s3://${S3_CACHE_BUCKET}?endpoint=${S3_CACHE_ENDPOINT}&region=${S3_CACHE_REGION:-auto}&secret-key=${keyfile}"

# What to push: explicit args, else the activated repo env's closure.
if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  # `cd … && pwd -P` resolves the $FLOX_ENV symlink to its store path portably
  # (macOS readlink lacks -f before 12.3).
  envpath="$(flox activate -- bash -c 'cd "$FLOX_ENV" && pwd -P')"
  paths=("$envpath")
fi

echo "+++ pushing ${#paths[@]} path(s) + closure to s3://${S3_CACHE_BUCKET} (signed)"
printf '    %s\n' "${paths[@]}"
nix --extra-experimental-features 'nix-command' \
  copy --to "$S3" "${paths[@]}"
echo "--- push complete"
