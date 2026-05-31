#!/usr/bin/env bash
# Diagnostic (opt-in via MEASURE_PKG_BREAKDOWN=1): find WHERE the ~42s
# `installer -pkg` spends its time.
#
# Build 13: the /nix store is tiny (324 MB, ~11.8k files, ~1s to restore) -- so
# the 40s is NOT store extraction.
# Build 14: the verbose install showed all the time is the postinstall "package
# scripts" phase (~25s on a reinstall, + ~15s volume creation on a cold one). The
# postinstall is a thin wrapper that execs /usr/local/share/flox/include/
# after-install.bash -- the standard Nix MULTI-USER installer.
#
# This dumps that real installer script + its includes (so we can see the slow
# parts -- expected: ~32 `nixbld` users via dscl, daemon/launchd setup), and
# greps for the suspected time sinks. The expensive timestamped verbose reinstall
# is now opt-in via MEASURE_PKG_BREAKDOWN=verbose (it costs another ~40s).
# Non-fatal; changes nothing permanent.
set -uo pipefail

: "${FLOX_VERSION:?set FLOX_VERSION}"
PKG="/tmp/flox-cache/flox-${FLOX_VERSION}.aarch64-darwin.pkg"

echo "+++ [breakdown] .pkg preinstall/postinstall scripts"
exp="$(cd "$(mktemp -d)" && pwd -P)/pkg"
pkgutil --expand-full "$PKG" "$exp" 2>/dev/null || pkgutil --expand "$PKG" "$exp" 2>/dev/null || echo "[breakdown] expand failed"
for name in preinstall postinstall; do
  while IFS= read -r f; do
    echo "===== [breakdown] pkg/$name ====="; sed -n '1,200p' "$f"
  done < <(find "$exp" -name "$name" -type f 2>/dev/null)
done
sudo rm -rf "$(dirname "$exp")" 2>/dev/null || true

echo ""
echo "+++ [breakdown] the REAL installer the postinstall execs, and its includes"
inc=/usr/local/share/flox/include
echo "--- [breakdown] ls $inc"
ls -la "$inc" 2>/dev/null || echo "[breakdown] $inc not found"
for f in "$inc"/*; do
  [ -f "$f" ] || continue
  echo "===== [breakdown] $f ($(wc -l <"$f" 2>/dev/null) lines) ====="
  sed -n '1,600p' "$f"
done

echo ""
echo "+++ [breakdown] suspected time sinks across the installer scripts"
grep -rniE 'dscl|nixbld|addVolume|createVolume|synthetic|launchctl|nix-daemon|sleep|--optimise|diskutil|createbuildusers' "$inc" 2>/dev/null | head -80

if [ "${MEASURE_PKG_BREAKDOWN:-}" = "verbose" ]; then
  echo ""
  echo "+++ [breakdown] timestamped VERBOSE reinstall (~40s) -- [+Ns] marks the slow phase"
  start=$(date +%s)
  sudo installer -verbose -dumplog -pkg "$PKG" -target / 2>&1 | while IFS= read -r line; do
    printf '[+%ss] %s\n' "$(( $(date +%s) - start ))" "$line"
  done
  echo "+++ [breakdown] reinstall wall time: $(( $(date +%s) - start ))s"
fi
echo "+++ [breakdown] done"
