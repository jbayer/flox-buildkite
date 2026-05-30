#!/usr/bin/env bash
# READ-PROOF: deterministically prove the agent can READ signed paths from the
# S3-compatible binary cache.
#
# Pulls the activated repo env's closure FROM the cache into a fresh throwaway
# store with signatures REQUIRED, so success can only mean the cache served
# signed paths that the agent's trusted public key accepts -- independent of
# whether the /nix cache volume happened to mount cold. The closure must already
# be in the cache (e.g. pushed by s3-cache-push.sh earlier in the same build).
#
# This lives in a script (not inline pipeline YAML) on purpose: Buildkite
# interpolates $VAR/${VAR} in inline `command:` blocks at upload time and would
# blank out the runtime shell variables below. Script files are not interpolated.
#
# Required env (non-secret):  S3_CACHE_BUCKET, S3_CACHE_ENDPOINT
# Optional env:               S3_CACHE_REGION (default "auto")
# Reads of a PRIVATE bucket also need AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
set -euo pipefail

# Graceful opt-out: empty/unset S3_CACHE_BUCKET means "no S3 cache" -- skip.
if [ -z "${S3_CACHE_BUCKET:-}" ]; then
  echo "--- S3 cache not configured (S3_CACHE_BUCKET empty); skipping read-proof"
  exit 0
fi
: "${S3_CACHE_ENDPOINT:?set S3_CACHE_ENDPOINT (full S3 endpoint URL)}"

# aws-sdk otherwise probes the (absent) instance-metadata endpoint and stalls.
export AWS_EC2_METADATA_DISABLED=true
s3="s3://${S3_CACHE_BUCKET}?endpoint=${S3_CACHE_ENDPOINT}&region=${S3_CACHE_REGION:-auto}"

# `cd … && pwd -P` resolves the $FLOX_ENV symlink portably (macOS readlink
# lacks -f before 12.3).
envpath="$(flox activate -- bash -c 'cd "$FLOX_ENV" && pwd -P')"
tmp="$(mktemp -d)"
proof_store="${tmp}/store"
trap 'chmod -R +w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

echo "+++ pulling $(basename "$envpath") from the cache into a fresh store (signatures required)"
nix --extra-experimental-features 'nix-command' \
  copy --from "$s3" --to "$proof_store" --option require-sigs true "$envpath"

if [ -e "${proof_store}/nix/store/$(basename "$envpath")" ]; then
  echo "+++ READ-PROOF OK: $(basename "$envpath") restored from the cache (signature-verified)"
else
  echo "!!! READ-PROOF FAILED: path absent after copy from the cache" >&2
  exit 1
fi
