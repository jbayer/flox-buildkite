#!/usr/bin/env bash
# macOS multi-user Nix: let the ROOT nix-daemon read a PRIVATE S3 binary cache.
#
# On macOS, substitute downloads are performed by the nix-daemon (running as
# root), NOT by the job -- so the job's S3 token never reaches it (this is the
# difference from single-user Linux). This script:
#   1. writes the S3 token to root's ~/.aws/credentials, where the daemon's
#      aws-sdk default credential chain looks (HOME=/var/root for the daemon);
#   2. restarts the nix-daemon so it reloads /etc/nix/nix.conf -- which
#      s3-cache-configure.sh just appended the substituter to -- and so its next
#      requests use the credentials above.
#
# No-op when the S3 cache is disabled (S3_CACHE_BUCKET empty). Requires
# passwordless sudo (the macOS pipeline already requires it for the .pkg) and
# `nix` on PATH (the caller puts it there).
#
# Requires in the env (e.g. loaded by s3-cache-load-secrets.sh):
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
set -euo pipefail

if [ -z "${S3_CACHE_BUCKET:-}" ]; then
  echo "--- S3 cache disabled (S3_CACHE_BUCKET empty); skipping macOS daemon auth"
  exit 0
fi
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"

echo "+++ writing S3 credentials to root's ~/.aws/credentials (read by the nix-daemon)"
sudo install -m 700 -d /var/root/.aws
# Pipe via stdin (not argv) so the secret never appears in the process list.
printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
  | sudo tee /var/root/.aws/credentials >/dev/null
sudo chmod 600 /var/root/.aws/credentials

echo "+++ restarting the nix-daemon so it reloads /etc/nix/nix.conf + finds the creds"
# The daemon reads its config at startup, so a restart is required after editing
# /etc/nix/nix.conf. Discover the launchd label (flox/nixos installers may name
# it differently), then kickstart; fall back to killing it (launchd respawns).
label="$(sudo launchctl list 2>/dev/null | awk '/nix-daemon/ {print $3; exit}')"
if [ -n "${label:-}" ]; then
  echo "    nix-daemon launchd label: $label -> kickstart -k"
  sudo launchctl kickstart -k "system/$label"
else
  echo "    no nix-daemon launchd label found; killing nix-daemon (launchd respawns)"
  sudo killall nix-daemon 2>/dev/null || true
fi

# Wait for the daemon socket to come back before we hand off to `flox activate`.
for _ in $(seq 1 10); do
  if nix --extra-experimental-features 'nix-command' store ping >/dev/null 2>&1; then
    echo "--- nix-daemon is back up"
    exit 0
  fi
  sleep 1
done
echo "WARNING: nix-daemon did not respond after restart; activate may be slow" >&2
