#!/usr/bin/env bash
# EXPERIMENTAL fast macOS Flox install for CI (opt-in via FAST_INSTALL=1).
#
# Why: the stock `.pkg` spends ~25s single-thread xz-decompressing the Nix store
# (build 15: `tar -xJpf` in after-install.bash), even though the store is tiny
# (324 MB, ~11.8k files, ~1s with zstd). This restores /nix from a zstd archive
# instead, and runs Nix SINGLE-USER -- a mode the flox installer itself supports
# (after-install.bash skips nixbld users + the nix-daemon when IS_SINGLEUSER),
# with `build-users-group =` already empty in /etc/nix/nix.conf. Single-user
# also means S3 reads use the job's own creds, exactly like the Linux flow (no
# root nix-daemon, no /var/root/.aws dance).
#
# Two modes:
#   --bootstrap <archive>  After a normal .pkg install, cache /nix (+ the flox
#                          bits + /etc/nix) as a zstd archive for future builds.
#   <archive>              Fast install: create /nix, restore the archive, hand
#                          the store to the job user. Returns non-zero on any
#                          problem so the caller can decide (fail fast for now).
#
# Unverified macOS scaffolding -- expect to iterate. Heavily logged on purpose.
set -uo pipefail

NIX_DATA_DIR="/System/Volumes/Data/nix"
APFS_UTIL="/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util"

bootstrap() {
  local archive="$1"
  echo "+++ [fast] bootstrap: caching /nix (+ flox bits + /etc/nix) -> $archive"
  # Everything a fast install must reproduce. /nix is the big one; the flox
  # binary + share live under /usr/local; nix.conf under /etc. Paths are relative
  # to / so the archive restores with `tar -x -C /`.
  time sudo tar --zstd -cf "$archive" -C / \
    nix \
    usr/local/bin/flox \
    usr/local/share/flox \
    etc/nix \
    2>/dev/null || { echo "[fast] bootstrap archive failed" >&2; return 1; }
  sudo chmod a+r "$archive" 2>/dev/null || true
  ls -lh "$archive" 2>/dev/null | awk '{print "--- [fast] archive size:", $5}'
}

fast_install() {
  local archive="$1"
  local me grp; me="$(id -un)"; grp="$(id -gn)"

  # Nix rejects a symlinked store (build 18: a `nix<TAB>target` synthetic.conf
  # entry makes /nix a symlink). So create a REAL APFS volume mounted at /nix:
  # an empty synthetic mountpoint + `diskutil apfs addVolume`.
  echo "+++ [fast] create /nix as a dedicated APFS volume (real dir; nix needs that)"
  if [ ! -d /nix ] || [ -L /nix ]; then
    [ -L /nix ] && sudo rm -f /nix                                   # drop stale symlink
    # Replace any prior `nix ...` entry with a bare `nix` (empty mountpoint).
    sudo sed -i '' -E '/^nix([[:space:]]|$)/d' /etc/synthetic.conf 2>/dev/null || true
    printf 'nix\n' | sudo tee -a /etc/synthetic.conf >/dev/null \
      || { echo "[fast] writing /etc/synthetic.conf failed" >&2; return 1; }
    sudo "$APFS_UTIL" -t 2>&1 | sed 's/^/   apfs.util: /'           # rc is unreliable; ignore it
    echo "   [fast] after apfs.util: /nix is $(ls -ld /nix 2>&1)"

    container="$(diskutil info -plist / | plutil -extract APFSContainerReference raw - 2>/dev/null)"
    [ -n "$container" ] || container="$(diskutil info / | awk -F': *' '/APFS Container( Reference)?:/{gsub(/ /,"",$2); print $2; exit}')"
    [ -n "$container" ] || container="$(diskutil info / | awk -F': *' '/Part of Whole:/{gsub(/ /,"",$2); print $2; exit}')"
    echo "   [fast] APFS container for /: ${container:-<none>}"
    [ -n "$container" ] || { echo "[fast] could not detect APFS container" >&2; return 1; }

    echo "   [fast] creating APFS volume 'Nix' on $container at /nix [timed]"
    time sudo diskutil apfs addVolume "$container" APFS Nix -mountpoint /nix 2>&1 | sed 's/^/   addVolume: /'
    [ "${PIPESTATUS[0]}" = 0 ] || { echo "[fast] addVolume failed" >&2; return 1; }
  fi
  for _ in 1 2 3 4 5; do { [ -d /nix ] && [ ! -L /nix ]; } && break; sleep 1; done
  { [ -d /nix ] && [ ! -L /nix ]; } || { echo "[fast] /nix not a real dir: $(ls -ld /nix 2>&1)" >&2; return 1; }
  echo "--- [fast] /nix ready: $(ls -ld /nix)"
  # Give the firmlink a moment to appear.
  for _ in 1 2 3 4 5; do [ -d /nix ] && break; sleep 1; done
  [ -d /nix ] || { echo "[fast] /nix did not appear after apfs.util -t" >&2; return 1; }
  echo "--- [fast] /nix -> $(readlink /nix 2>/dev/null || echo '(dir)')"

  echo "+++ [fast] restore store from archive (zstd) [timed]"
  # -P: macOS /etc is a symlink to /private/etc, and bsdtar otherwise refuses to
  # extract etc/nix/* "through a symlink". -P disables that guard (the target,
  # /private/etc/nix, is the real, correct location).
  time sudo tar -P --zstd -xf "$archive" -C / || { echo "[fast] restore failed" >&2; return 1; }

  echo "+++ [fast] hand /nix to '$me' (single-user; no daemon) [timed]"
  time sudo chown -R "$me:$grp" /nix || { echo "[fast] chown /nix failed" >&2; return 1; }

  export PATH="/usr/local/bin:$PATH"
  command -v flox >/dev/null 2>&1 || { echo "[fast] flox not on PATH after restore" >&2; return 1; }
  NIX_REMOTE=auto flox --version || { echo "[fast] flox --version failed" >&2; return 1; }
  echo "+++ [fast] single-user Nix ready"
}

case "${1:-}" in
  --bootstrap) shift; [ -n "${1:-}" ] || { echo "usage: --bootstrap <archive>" >&2; exit 2; }; bootstrap "$1" ;;
  "")          echo "usage: $0 [--bootstrap] <archive>" >&2; exit 2 ;;
  *)           fast_install "$1" ;;
esac
