#!/usr/bin/env bash
# Region discovery for a Buildkite HOSTED Linux agent. Prints the egress public
# IP, its ASN/org and geo, and probes cloud metadata endpoints. Buildkite hosted
# agents run in a US East Coast *private* cloud (not AWS/GCP/Azure), so the cloud
# metadata probes are expected to find nothing -- that absence is itself a signal.
#
# Informational only: installs nothing, changes nothing, and never fails the
# build (no `set -e`; probes are allowed to fail). Run as one bash invocation
# (hosted agents don't preserve shell state across inline command lines).
set -uo pipefail

echo "--- egress public IP + geo/ASN (ipinfo.io)"
# Returns JSON: ip, city, region, country, org (ASN + name), loc, timezone.
curl -fsS --max-time 10 https://ipinfo.io || echo "(ipinfo.io unreachable)"
echo

EGRESS=$(curl -fsS --max-time 10 https://ipinfo.io/ip || true)
echo "--- reverse DNS of egress IP (${EGRESS:-unknown})"
if [ -n "${EGRESS:-}" ]; then
  if command -v dig >/dev/null 2>&1; then dig +short -x "$EGRESS"
  elif command -v host >/dev/null 2>&1; then host "$EGRESS"
  else echo "(no dig/host available)"; fi
fi
echo

echo "--- cloud metadata probes (a private cloud answers none of these)"
if curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null; then
  echo "  ^ responded: AWS region"
else echo "AWS IMDS: no response"; fi
if curl -fsS --max-time 2 -H "Metadata-Flavor: Google" \
     http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null; then
  echo "  ^ responded: GCP zone"
else echo "GCP metadata: no response"; fi
if curl -fsS --max-time 2 -H "Metadata: true" \
     "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" 2>/dev/null; then
  echo "  ^ responded: Azure location"
else echo "Azure metadata: no response"; fi
echo

echo "--- any region/zone/cloud hints in the job environment"
env | grep -iE 'region|zone|cloud|datacenter' || echo "(none)"
