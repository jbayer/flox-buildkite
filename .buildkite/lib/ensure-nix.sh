#!/usr/bin/env bash
# Seed the /nix cache volume from the copy baked into the agent image.
#
# Why: Flox + its bundled Nix live entirely under /nix/store, and the Buildkite
# cache volume mounted at /nix is empty on the first build (and after eviction).
# That empty volume shadows the /nix baked into the image, so /usr/bin/flox
# becomes a dangling symlink. We restore a working store by copying the stash
# at /opt/nix-seed (created in the Dockerfile, outside /nix so it isn't shadowed)
# into the volume whenever the volume is cold.
#
# Idempotent: on a warm volume (Flox already usable) this is a no-op, so it is
# safe to call at the top of every step that uses Flox.
set -euo pipefail

# `-x` follows the symlink: true only if the target exists and is executable.
# On a cold volume the target is missing (dangling) -> false -> seed.
if [ -x /usr/bin/flox ]; then
  echo "--- /nix cache volume is warm (flox usable); skipping seed"
  flox --version
  exit 0
fi

if [ ! -d /opt/nix-seed ]; then
  echo "!!! flox is not usable and there is no /opt/nix-seed to seed from." >&2
  echo "!!! Is this running on the custom agent image from .buildkite/agent-image/?" >&2
  exit 1
fi

echo "+++ cold /nix cache volume: seeding from /opt/nix-seed (one-time per cold volume)"
time cp -a /opt/nix-seed/. /nix/
flox --version
echo "--- seed complete"
