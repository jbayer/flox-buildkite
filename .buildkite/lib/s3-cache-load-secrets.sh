#!/usr/bin/env bash
# SOURCE this (do not `bash` it) to load the S3 binary-cache secrets into the
# current shell so later commands -- `flox activate` (reads) and s3-cache-push.sh
# (writes) -- can authenticate:
#
#     source .buildkite/lib/s3-cache-load-secrets.sh
#
# Behaviour is keyed on the non-secret S3_CACHE_BUCKET (from the pipeline env):
#   - bucket empty/unset  -> S3 cache disabled; return cleanly (no-op). The
#                            standard pipeline then runs with just the /nix volume.
#   - bucket set          -> the three cluster secrets are REQUIRED; a missing one
#                            fails loudly (a configured cache with no creds is a
#                            mistake, not a silent skip).
#
# On success it exports AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and
# S3_CACHE_SIGNING_KEY, and registers the signing key with the log redactor.
#
# Secrets fetched (Agents -> cluster -> Secrets):
#   S3_CACHE_ACCESS_KEY_ID, S3_CACHE_SECRET_ACCESS_KEY, S3_CACHE_SIGNING_KEY

if [ -z "${S3_CACHE_BUCKET:-}" ]; then
  echo "--- S3 cache disabled (S3_CACHE_BUCKET empty); using /nix volume only"
  return 0 2>/dev/null || exit 0
fi

# `|| true` so a missing secret yields empty (and a clear error below) rather
# than tripping `set -e` in the sourcing step.
_ak="$(buildkite-agent secret get S3_CACHE_ACCESS_KEY_ID 2>/dev/null || true)"
_sk="$(buildkite-agent secret get S3_CACHE_SECRET_ACCESS_KEY 2>/dev/null || true)"
_sign="$(buildkite-agent secret get S3_CACHE_SIGNING_KEY 2>/dev/null || true)"

if [ -z "$_ak" ] || [ -z "$_sk" ] || [ -z "$_sign" ]; then
  echo "!!! S3_CACHE_BUCKET is set but one or more cache secrets are missing." >&2
  echo "!!! Add cluster secrets S3_CACHE_ACCESS_KEY_ID, S3_CACHE_SECRET_ACCESS_KEY," >&2
  echo "!!! and S3_CACHE_SIGNING_KEY -- or clear S3_CACHE_BUCKET to disable the cache." >&2
  unset _ak _sk _sign
  # `exit` (not `return`): when sourced this aborts the step shell directly, so a
  # misconfigured cache fails the build loudly regardless of the caller's set -e.
  exit 1
fi

export AWS_ACCESS_KEY_ID="$_ak"
export AWS_SECRET_ACCESS_KEY="$_sk"
export S3_CACHE_SIGNING_KEY="$_sign"
buildkite-agent redactor add <<<"$_sign" >/dev/null 2>&1 || true
unset _ak _sk _sign
echo "--- S3 cache secrets loaded for bucket '$S3_CACHE_BUCKET' (reads + writes enabled)"
return 0 2>/dev/null || exit 0
