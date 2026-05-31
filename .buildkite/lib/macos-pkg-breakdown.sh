#!/usr/bin/env bash
# Diagnostic (opt-in via MEASURE_PKG_BREAKDOWN=1): find WHERE the ~42s
# `installer -pkg` spends its time.
#
# Build 13 showed the /nix store is tiny -- 324 MB, ~11.8k files, ~1s to
# archive AND ~1s to restore -- so the 40s is NOT store extraction. It's macOS
# install scaffolding. This dumps the .pkg's install scripts (what it actually
# does) and runs a timestamped verbose (re)install so the slow phase is visible.
#
# Read-only-ish: it re-runs `installer` over an already-installed /nix. If that
# reinstall is FAST, the 40s was one-time volume creation (skipped when /nix
# already exists); if it's still ~40s, the cost is redone every time. Either
# answer tells us whether a custom installer can avoid it. Non-fatal.
set -uo pipefail

: "${FLOX_VERSION:?set FLOX_VERSION}"
PKG="/tmp/flox-cache/flox-${FLOX_VERSION}.aarch64-darwin.pkg"

echo "+++ [breakdown] expand the .pkg and dump its install scripts"
exp="$(cd "$(mktemp -d)" && pwd -P)/pkg"
if ! pkgutil --expand-full "$PKG" "$exp" 2>/dev/null; then
  pkgutil --expand "$PKG" "$exp" 2>/dev/null || echo "[breakdown] pkg expand failed"
fi
echo "--- [breakdown] package tree"
find "$exp" -maxdepth 3 2>/dev/null | sed "s#$exp#pkg#" | head -50
for name in PackageInfo Distribution preinstall postinstall; do
  while IFS= read -r found; do
    [ -n "$found" ] || continue
    echo "===== [breakdown] $(echo "$found" | sed "s#$exp#pkg#") ====="
    sed -n '1,250p' "$found"
  done < <(find "$exp" -name "$name" -type f 2>/dev/null)
done

echo ""
echo "+++ [breakdown] timestamped VERBOSE reinstall -- [+Ns] marks the slow phase"
start=$(date +%s)
sudo installer -verbose -dumplog -pkg "$PKG" -target / 2>&1 | while IFS= read -r line; do
  printf '[+%ss] %s\n' "$(( $(date +%s) - start ))" "$line"
done
echo "+++ [breakdown] reinstall wall time: $(( $(date +%s) - start ))s"

sudo rm -rf "$(dirname "$exp")" 2>/dev/null || true
echo "+++ [breakdown] done"
