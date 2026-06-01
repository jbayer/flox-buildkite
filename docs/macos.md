# macOS hosted agents

[← docs index](README.md) · [← main README](../README.md)

Buildkite's **macOS** hosted agents work differently from Linux, so Flox is set
up differently — see `.buildkite/pipeline.macos.yml`, which runs
`.buildkite/lib/macos-install-flox.sh`. Verified on the built-in `macos-medium`
queue. Two constraints drive the approach:

- **No custom agent images.** Unlike Linux, you can't bake Flox into the base
  image, so Flox comes from its macOS `.pkg`.
- **`/nix` is a system APFS volume with a daemon.** macOS Nix is multi-user, so
  you can't bind-mount a cache volume over `/nix` as on Linux. Warmth comes from
  a binary cache / substituter, not from caching the `/nix` mount.

## Fast install (~42s → ~2s)

The stock `installer -pkg` is ~42s — and a breakdown showed that's almost
entirely **single-threaded xz decompression** of the Nix store (the store itself
is tiny: 324 MB, ~12k files, ~1s with zstd). So `macos-install-flox.sh` uses a
**fast install** (on by default; `FAST_INSTALL=0` to disable):

- **Bootstrap** (first build on a fresh cache volume): run the `.pkg` once, then
  cache `/nix` as a **zstd** archive on the persistent `/tmp/flox-cache` volume.
- **Fast path** (every build after): create a real `/nix` APFS volume
  (`diskutil addVolume`, ~0.6s), **zstd-restore the store** (~1s), and run Nix
  **single-user** — a mode the flox installer supports (no daemon, no `nixbld`
  users), so `/nix` is owned by the job user just like Linux. **~42s → ~2s.** If
  the fast path ever fails, it cleans up and falls back to the `.pkg`.

Single-user also means the **S3 read uses the job's own creds** (no root daemon),
so the fast path skips the `/var/root` daemon-auth dance. (`macos-s3-daemon-auth.sh`
is still used on the `.pkg`/`FAST_INSTALL=0` multi-user path.) Details of how this
was discovered: [internals](internals.md).

## Wiring it to a Mac

`pipeline.macos.yml` targets **`macos-medium`**, a built-in Buildkite hosted macOS
queue, so it routes out of the box (swap for `macos-large` for more resources).
Point a pipeline's **Steps** at the file:

```yaml
steps:
  - command: buildkite-agent pipeline upload .buildkite/pipeline.macos.yml
```

The `pipeline upload` runs on whatever queue handles the build's first step (any
queue — it only parses YAML); the install/activate step then dispatches to
`macos-medium` via its `agents: { queue: "macos-medium" }` tag. If the build
stalls at the upload step, the pipeline's default queue has no agents — set that
default to `macos-medium` too.

It checks for **passwordless sudo** first and fails fast if missing (the `.pkg` /
APFS volume creation need root; `macos-medium` grants it).

For activate to work on macOS, the repo env must list `aarch64-darwin` in
`.flox/env/manifest.toml` `[options] systems` with a regenerated lockfile.

## S3 cache on macOS

`pipeline.macos.yml` wires in the same [S3 binary cache](s3-cache.md) as the
other queues (there's no `/nix` cache volume on macOS). On the **fast/single-user**
path it behaves like Linux. On the `.pkg`/multi-user path there's a macOS twist
for the **read** side:

- macOS multi-user Nix has the **root `nix-daemon`** — not the job — perform
  substitute downloads, and the job's S3 token never reaches it.
  `macos-s3-daemon-auth.sh` writes the token to root's `~/.aws/credentials` and
  **restarts the daemon** so it reloads the substituter `s3-cache-configure.sh`
  added to `/etc/nix/nix.conf`.
- The **write-back** is client-side. macOS Nix's `curl` (OpenSSL) has **no default
  CA bundle**, so the client would fail with `curlCode 60`; the script sets
  `NIX_SSL_CERT_FILE` to a CA bundle so `nix copy` works.
- The S3 setup is **non-fatal**: on any quirk it logs a warning and `flox
  activate` falls back to upstream, so it can't break a working build.

> ✅ Verified on a real macOS hosted build (`macos-medium`): fast single-user
> install (~2s), `flox activate` green, and S3 read/write working. The cold
> bootstrap path (.pkg + archive) and the multi-user `.pkg` path are also verified.
