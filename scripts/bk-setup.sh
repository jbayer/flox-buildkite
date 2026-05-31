#!/usr/bin/env bash
# Automate the bk-scriptable parts of setting this repo up on Buildkite, given an
# AUTHENTICATED `bk` CLI (run `bk configure --org <org> --token <token>` first;
# install with `flox install buildkite-cli`).
#
# DOES:
#   - create a pipeline pointed at your repo (its default step uploads
#     .buildkite/pipeline.yml)
#   - print the `bk secret create` commands for the OPTIONAL S3 cache
#   - optionally trigger a first build (--build)
#
# DOES NOT (these are Buildkite UI steps -- see README "Quick start"):
#   - build the custom agent image   (Agents -> cluster -> Agent Images)
#   - attach it to your Linux queue   (Queues -> Base image)
#
# Usage:
#   ORG=my-org CLUSTER=<cluster-slug> REPO=git@github.com:you/flox-buildkite.git \
#     PIPELINE=flox-buildkite ./scripts/bk-setup.sh [--build] [--no-s3]
set -euo pipefail

: "${ORG:?set ORG (Buildkite org slug)}"
: "${CLUSTER:?set CLUSTER (cluster slug or UUID)}"
: "${REPO:?set REPO (git URL of your fork)}"
PIPELINE="${PIPELINE:-flox-buildkite}"

want_build=0 want_s3=1
for a in "$@"; do case "$a" in
  --build) want_build=1 ;;
  --no-s3) want_s3=0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

command -v bk >/dev/null 2>&1 || {
  echo "bk not found. Install it: flox install buildkite-cli" >&2; exit 1; }

echo "--- creating pipeline '$PIPELINE' (cluster '$CLUSTER', repo '$REPO')"
bk pipeline create --name "$PIPELINE" --repository "$REPO" --cluster "$CLUSTER" \
  --description "Flox on Buildkite (created by scripts/bk-setup.sh)" \
  || echo "(pipeline may already exist; continuing)"

if [ "$want_build" = 1 ]; then
  echo "--- triggering a first build on main"
  bk build create -p "$PIPELINE" -b main -m "bk-setup: first build" || true
fi

if [ "$want_s3" = 1 ]; then
  cat <<EOF

--- OPTIONAL: enable the S3 binary cache by creating these cluster secrets
    (bk prompts for each value, so they stay out of your shell history):

      bk secret create S3_CACHE_ACCESS_KEY_ID     --cluster $CLUSTER
      bk secret create S3_CACHE_SECRET_ACCESS_KEY --cluster $CLUSTER
      bk secret create S3_CACHE_SIGNING_KEY       --cluster $CLUSTER

    ...and set the non-secret S3_CACHE_* vars in pipeline.yml's env: block.
    Skip all of this to run without a cache (builds still pass). --no-s3 hides
    this reminder.
EOF
fi

cat <<'EOF'

--- REMAINING MANUAL STEPS (Buildkite UI; bk can't do these):
  1. Agents -> cluster -> Agent Images -> New Image named 'flox-agent':
     paste .buildkite/agent-image/Dockerfile MINUS its FROM line.
  2. Agents -> cluster -> Queues -> your Linux queue -> Base image -> flox-agent.
  Then run a build. Full walkthrough: README "Quick start".
EOF
