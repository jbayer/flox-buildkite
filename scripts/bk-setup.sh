#!/usr/bin/env bash
# Automate the bk-scriptable parts of setting this repo up on Buildkite, given an
# AUTHENTICATED `bk` CLI (install: `flox install buildkite-cli`, then
# `bk configure --org <org> --token <token>`). Flags verified against bk 3.42.
#
# DOES:
#   - create a pipeline pointed at your repo. Buildkite runs the repo's
#     .buildkite/pipeline.yml by default, so no steps need configuring.
#   - print the (correct) `bk secret create` commands for the OPTIONAL S3 cache.
#   - with --build: trigger + watch a first build. That green build IS the
#     prerequisite check (see below).
#
# DOES NOT (Buildkite UI only -- not exposed by `bk` or the REST API):
#   - build the custom agent image   (Agents -> cluster -> Agent Images)
#   - attach it to your Linux queue   (Queues -> Base image)
#   There is NO bk/API call to verify the agent image exists, so a green build
#   is the real prerequisite check -- run with --build.
#
# Usage (get CLUSTER_UUID from `bk cluster list`):
#   ORG=my-org CLUSTER_UUID=<uuid> REPO=git@github.com:you/flox-buildkite.git \
#     PIPELINE=flox-buildkite ./scripts/bk-setup.sh [--build] [--webhook] [--no-s3]
set -euo pipefail

: "${ORG:?set ORG (Buildkite org slug)}"
: "${CLUSTER_UUID:?set CLUSTER_UUID (from 'bk cluster list')}"
: "${REPO:?set REPO (git URL of your fork)}"
PIPELINE="${PIPELINE:-flox-buildkite}"   # keep it slug-friendly (no spaces)

want_build=0 want_s3=1 want_webhook=0
for a in "$@"; do case "$a" in
  --build)   want_build=1 ;;
  --no-s3)   want_s3=0 ;;
  --webhook) want_webhook=1 ;;   # also set up the GitHub webhook (needs the GH integration)
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

command -v bk >/dev/null 2>&1 || {
  echo "bk not found. Install it: flox install buildkite-cli" >&2; exit 1; }

echo "--- creating pipeline '$PIPELINE' (cluster $CLUSTER_UUID, repo $REPO)"
webhook_flag=(); [ "$want_webhook" = 1 ] && webhook_flag=(--create-webhook)
bk pipeline create "$PIPELINE" --org "$ORG" --repository "$REPO" \
  --cluster-uuid "$CLUSTER_UUID" \
  --description "Flox on Buildkite (created by scripts/bk-setup.sh)" \
  "${webhook_flag[@]}" \
  || echo "(pipeline may already exist; continuing)"
echo "    Buildkite runs the repo's .buildkite/pipeline.yml by default -- no steps to set."

if [ "$want_build" = 1 ]; then
  echo "--- triggering + watching a first build on main (this IS the prereq check)"
  bk build create -p "$PIPELINE" -b main -m "bk-setup: first build" || true
  bk build watch -p "$PIPELINE" || true
fi

if [ "$want_s3" = 1 ]; then
  cat <<EOF

--- OPTIONAL: enable the S3 binary cache by creating these cluster secrets
    (bk prompts for each value, so they stay out of your shell history):

      bk secret create --cluster-uuid $CLUSTER_UUID --key S3_CACHE_ACCESS_KEY_ID
      bk secret create --cluster-uuid $CLUSTER_UUID --key S3_CACHE_SECRET_ACCESS_KEY
      bk secret create --cluster-uuid $CLUSTER_UUID --key S3_CACHE_SIGNING_KEY

    ...and set the non-secret S3_CACHE_* vars in your pipeline's env: block
    (see docs/s3-cache.md / README building blocks 3 & 4).
    Reads are the default; WRITE-BACK is opt-in (set S3_CACHE_PUSH=1, which also
    needs S3_CACHE_SIGNING_KEY). Skip all of this to run without a cache.
    --no-s3 hides this reminder.
EOF
fi

cat <<'EOF'

--- REMAINING MANUAL STEPS (Buildkite UI; bk/REST can't do or verify these):
  1. Agents -> cluster -> Agent Images -> New Image named 'flox-agent':
     paste .buildkite/agent-image/Dockerfile MINUS its FROM line.
  2. Agents -> cluster -> Queues -> your Linux queue -> Base image -> flox-agent.
  Then re-run with --build (or click New Build). A green build = prereqs satisfied.
EOF
