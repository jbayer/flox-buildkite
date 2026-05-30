#!/usr/bin/env bash
# READ-PROOF: deterministically prove the agent can READ signed paths from R2.
#
# Pulls the activated repo env's closure FROM R2 into a fresh throwaway store
# with signatures REQUIRED, so success can only mean R2 served signed paths that
# the agent's trusted public key accepts -- independent of whether the /nix
# cache volume happened to mount cold. The closure must already be in R2 (e.g.
# pushed by r2-push.sh earlier in the same build).
#
# This lives in a script (not inline pipeline YAML) on purpose: Buildkite
# interpolates $VAR/${VAR} in inline `command:` blocks at upload time and would
# blank out the runtime shell variables below. Script files are not interpolated.
#
# Required env (non-secret):  R2_BUCKET, R2_ACCOUNT_ID
# Reads of a PRIVATE bucket also need AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
set -euo pipefail

: "${R2_BUCKET:?set R2_BUCKET}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"

# aws-sdk otherwise probes the (absent) instance-metadata endpoint and stalls.
export AWS_EC2_METADATA_DISABLED=true
s3="s3://${R2_BUCKET}?endpoint=https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com&region=auto"

envpath="$(flox activate -- bash -c 'readlink -f "$FLOX_ENV"')"
tmp="$(mktemp -d)"
proof_store="${tmp}/store"
trap 'chmod -R +w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

echo "+++ pulling $(basename "$envpath") from R2 into a fresh store (signatures required)"
nix --extra-experimental-features 'nix-command' \
  copy --from "$s3" --to "$proof_store" --option require-sigs true "$envpath"

if [ -e "${proof_store}/nix/store/$(basename "$envpath")" ]; then
  echo "+++ READ-PROOF OK: $(basename "$envpath") restored from R2 (signature-verified)"
else
  echo "!!! READ-PROOF FAILED: path absent after copy from R2" >&2
  exit 1
fi
