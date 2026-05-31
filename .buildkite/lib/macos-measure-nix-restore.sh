#!/usr/bin/env bash
# ONE-TIME MEASUREMENT (not part of normal builds). Sizes the prize for a
# "cache the store + restore it" macOS installer vs the ~42s `installer -pkg`.
#
# Run it by triggering ONE build with MEASURE_NIX_RESTORE=1 in the environment
# (Buildkite "New Build" -> Environment Variables, or `bk build create -e
# MEASURE_NIX_RESTORE=1`). It runs AFTER the .pkg install (so /nix is populated),
# changes nothing permanent, and is fully non-fatal.
#
# What it reports:
#   - total /nix size + file count (what any restore must reproduce)
#   - ARCHIVE: time to tar+compress /nix  (a ONE-TIME bootstrap cost in a real
#     installer -- the archive would be cached on the persistent /tmp/flox-cache)
#   - RESTORE: time to extract that archive into a scratch dir  (the PER-BUILD
#     cost a cache-and-restore installer would actually pay -- compare to ~42s)
#
# Caveats: the restore target is a normal dir, not a fresh APFS /nix volume, so
# RESTORE is a *lower bound* -- a real installer also pays APFS volume creation +
# nixbld user setup + one nix-daemon start on top of this.
set -uo pipefail   # deliberately NO -e: a measurement must never fail the build

echo "+++ [measure] sizing a cache-and-restore installer vs the ~42s installer -pkg"

echo "--- [measure] /nix size + file count"
sudo du -sh /nix 2>/dev/null || true
printf '[measure] /nix file count: '; sudo find /nix 2>/dev/null | wc -l || true

# Prefer zstd (what a real installer would use) via libarchive; else gzip.
if tar --zstd -cf /dev/null -T /dev/null >/dev/null 2>&1; then
  ZFLAG="--zstd"; EXT="zst"; echo "--- [measure] compressor: zstd (libarchive, multi-threaded)"
else
  ZFLAG="-z";     EXT="gz";  echo "--- [measure] compressor: gzip (zstd unavailable; pessimistic vs zstd)"
fi

work="$(cd "$(mktemp -d)" && pwd -P)"
archive="$work/nix.tar.$EXT"
dest="$work/restore"; mkdir -p "$dest"

echo "--- [measure] ARCHIVE (one-time bootstrap cost): tar $ZFLAG of /nix"
time sudo tar "$ZFLAG" -cf "$archive" -C /nix . 2>/dev/null || echo "[measure] archive step failed"
sudo ls -lh "$archive" 2>/dev/null | awk '{print "[measure] archive size:", $5}'

echo "--- [measure] RESTORE (the per-build cost to compare vs ~42s): extract -> scratch"
time sudo tar "$ZFLAG" -xf "$archive" -C "$dest" 2>/dev/null || echo "[measure] restore step failed"

echo "--- [measure] cleanup"
sudo rm -rf "$work" 2>/dev/null || true
echo "+++ [measure] done. Compare RESTORE wall time (+ scaffolding) against ~42s."
