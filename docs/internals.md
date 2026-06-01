# Internals — why it's built this way

[← docs index](README.md) · [← main README](../README.md)

Background and findings behind some of the less-obvious design choices. You don't
need this to use the repo — it's here so the choices are auditable.

## Why the macOS install was 42s — and how it became ~2s

The stock Flox macOS `.pkg` takes **~42s** to install. Measuring it:

- The Nix store it lays down is tiny: **324 MB, ~11.8k files**, and archives +
  restores in **~1s** with `zstd`.
- A timestamped `installer -verbose` run pinned ~25s to the postinstall "package
  scripts" phase, which execs `after-install.bash` → `flox_extract_nix()` →
  `tar -C / -xJpf …`. **`-J` is xz** — single-threaded decompression is the cost,
  not file I/O.
- The remaining time was the `.pkg`'s encrypted-volume + nix-daemon setup, which
  CI doesn't need.

So `macos-fast-install.sh` restores the store from a **zstd** archive (~1s) into a
real APFS volume created with `diskutil addVolume` (~0.6s — far cheaper than the
`.pkg`'s ~15s because it's unencrypted and has no boot-mount daemon), and runs Nix
**single-user**. The flox installer itself supports single-user (it guards
`nixbld` users + the daemon behind `IS_SINGLEUSER`, and ships `build-users-group =`
empty in `/etc/nix/nix.conf`). Net: **~42s → ~1.8s**. See [macOS](macos.md).

The cleaner long-term fix is upstream: if the `.pkg` shipped the store as zstd
(or decompressed multi-threaded), everyone would get this with no custom code.

### macOS gotchas the iteration surfaced

- **`/nix` must be a real directory**, not a symlink — a `synthetic.conf`
  `nix<TAB>target` firmlink makes `/nix` a symlink, which Nix rejects (same rule
  that rejects `/var` symlinks). Hence the real APFS volume.
- **`/etc` is a symlink** to `/private/etc`, so restoring `etc/nix/*` needs
  `tar -P` (bsdtar otherwise refuses to "extract through a symlink").
- **No default CA bundle** for macOS Nix's OpenSSL curl → client `nix copy` fails
  with `curlCode 60` until `NIX_SSL_CERT_FILE` is set.
- **macOS `mktemp -d`** returns paths under `/var` (a symlink), so a throwaway
  chroot store path must be canonicalized with `pwd -P`.

## Where hosted agents run

Buildkite hosted agents run in a US East Coast **private cloud** (not AWS/GCP/
Azure): a hosted Linux job egresses from **Northern Virginia** (`iad`) on
**Namespace** (`AS401483`), and cloud metadata endpoints answer nothing. That's
why an S3 binary cache should sit near `iad` / `us-east-1` for low-latency cold
pulls.

## Buildkite inline-YAML interpolation

Buildkite interpolates `$VAR`/`${VAR}` in **inline `command:` blocks** at
pipeline-upload time, blanking anything undefined then. That's why all real logic
lives in `.buildkite/lib/*.sh` **script files** (not interpolated) and the
pipelines only call them; and why the one inline secret reference is escaped `$$`.
