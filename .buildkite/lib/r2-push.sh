#!/usr/bin/env bash
# WRITE path: push (write back) Nix store paths to the R2 binary cache, SIGNED,
# so future COLD builds substitute them from R2 instead of re-downloading from
# upstream. This is the counterpart to r2-configure.sh (the read path).
#
# By default it pushes the closure of the ACTIVATED repo environment ($FLOX_ENV)
# -- i.e. the env plus every package `flox activate` realized, which is exactly
# what a cold build needs warm. Pass explicit /nix/store/... paths as arguments
# to push something else instead.
#
# Required env (non-secret):
#   R2_BUCKET             e.g. flox-binary-cache
#   R2_ACCOUNT_ID         the hex id in your R2 S3 endpoint host
#
# Required env (SECRET -- inject at runtime, e.g. via Buildkite cluster secrets;
# never bake these into the image):
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   the R2 API token (S3-compatible)
#   R2_CACHE_SIGNING_KEY                         the Nix secret signing key TEXT
#     (or set R2_CACHE_SIGNING_KEY_FILE to a path holding the key instead)
#
# The signing key is the one credential that must be guarded: anyone holding it
# can place trusted paths in your cache. This script writes it to a 0600 temp
# file, uses it, and deletes it on exit; it is never echoed.
set -euo pipefail

: "${R2_BUCKET:?set R2_BUCKET}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID (R2 access key id)}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY (R2 secret access key)}"

# aws-sdk otherwise probes the (absent) instance-metadata endpoint and stalls.
export AWS_EC2_METADATA_DISABLED=true
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Resolve the signing key into a private temp file; clean it up on exit.
keyfile="${R2_CACHE_SIGNING_KEY_FILE:-}"
tmpkey=""
if [ -z "$keyfile" ]; then
  : "${R2_CACHE_SIGNING_KEY:?set R2_CACHE_SIGNING_KEY or R2_CACHE_SIGNING_KEY_FILE}"
  tmpkey="$(mktemp)"
  keyfile="$tmpkey"
  ( umask 177; printf '%s' "$R2_CACHE_SIGNING_KEY" >"$keyfile" )
fi
cleanup() { [ -n "$tmpkey" ] && rm -f "$tmpkey"; return 0; }
trap cleanup EXIT

S3="s3://${R2_BUCKET}?endpoint=${ENDPOINT}&region=auto&secret-key=${keyfile}"

# What to push: explicit args, else the activated repo env's closure.
if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  envpath="$(flox activate -- bash -c 'readlink -f "$FLOX_ENV"')"
  paths=("$envpath")
fi

echo "+++ pushing ${#paths[@]} path(s) + closure to s3://${R2_BUCKET} (signed)"
printf '    %s\n' "${paths[@]}"
nix --extra-experimental-features 'nix-command' \
  copy --to "$S3" "${paths[@]}"
echo "--- push complete"
