# flox-buildkite

Run [Flox](https://flox.dev) environments on [Buildkite](https://buildkite.com) —
start in **one pipeline file**, then optionally make it faster.

This repo is a set of **composable building blocks** (small scripts + step
snippets) plus an optional custom agent image. Copy the pieces you need into your
own repo. **[docs/](docs/README.md)** has more detail.

## Buildkite hosted agent

| | Setup | Install cost per build |
| --- | --- | --- |
| **Tier 0 — install per build** | a pipeline step (any Linux queue) | does the Flox install each build |
| **Tier 1 — faster install** | a custom agent image **and/or** a `/nix` cache volume | ~free (Flox already present) |
| **+ Binary cache** *(optional)* | cluster secrets + env | composes with Tier 0 *or* 1; downloads from a durable cache |

Start at **Tier 0** — it works on any Linux hosted queue with zero UI setup. Move
to Tier 1 when the per-build install time bothers you. Add the binary cache
anytime; it's an orthogonal integration that layers on either tier.

## Quick start (Tier 0)

A green build on any Linux hosted queue, no custom image. You already have a
`.flox/` environment in your repo (that's why you're here).

1. **Copy** `.buildkite/lib/linux-install-flox.sh` into your repo.
2. **Add a pipeline file** (e.g. `.buildkite/pipeline.yml`):
   ```yaml
   env:
     NIX_REMOTE: "auto"            # single-user Nix (no daemon)
     FLOX_SHELL: "bash"            # CI has no tty -- silences flox's shell-detect warning
     # FLOX_VERSION: "1.12.1"      # optional: pin a version (default: latest stable)
   steps:
     - command: |
         bash .buildkite/lib/linux-install-flox.sh    # installs Flox if not already present
         flox activate -- <your build command>  # e.g. make test
   ```
   (A copy-ready version is `.buildkite/examples/pipeline.minimal.yml`.)
3. **Create a Buildkite pipeline** pointed at your repo — its default step runs
   `.buildkite/pipeline.yml`. Run a build → **green** when your command runs
   inside Flox.

That's it: one script + one pipeline file. Prefer to script the Buildkite side?
See [Automation](docs/automation.md) (`scripts/bk-setup.sh`).

## Make it faster (Tier 1)

`linux-install-flox.sh` is a **no-op when Flox is already present**, so Tier 1 is purely
additive — it just makes Flox *already there*:

- **Custom agent image** — bake Flox (and heavy runtimes) into the agent so every
  build is install-free. Register `.buildkite/agent-image/Dockerfile` as an agent
  image and attach it to your queue.
- **`/nix` cache volume** — persist `/nix` across builds (best-effort), with the
  *seed pattern* so a cold volume self-heals (`.buildkite/lib/ensure-nix.sh`).

This repo's `.buildkite/pipeline.yml` is the worked Tier-1 example (image + volume
+ optional cache). Full runbook, seed pattern, and `SEED_PACKAGES`:
**[docs/hosted-linux.md](docs/hosted-linux.md)**.

## Optional: a binary cache

An S3-compatible Nix cache (AWS S3, CloudFlare R2, MinIO, …) so cold builds pull
prebuilt paths from nearby durable storage instead of upstream. **Composes with
Tier 0 or Tier 1.** Reads are the default; write-back is opt-in. Setup, signing
keys, and private-vs-public reads: **[docs/s3-cache.md](docs/s3-cache.md)**. The
step snippet is block 3 below.

## Pipeline building blocks

Compose your steps from these. The only one you *need* is **activate**.

**1 — Install Flox** (Tier 0; a no-op under a custom image):
```yaml
env: { NIX_REMOTE: "auto", FLOX_SHELL: "bash" }   # add FLOX_VERSION to pin (default: latest)
steps:
  - command: bash .buildkite/lib/linux-install-flox.sh
```

**2 — Activate + run** (the essential pattern):
```yaml
steps:
  - command: flox activate -- make test      # any command
```
> CI has no tty, so `flox activate` logs `Failed to detect shell … Defaulting to
> bash`. Silence it by telling flox the shell — either in `env:` (`FLOX_SHELL:
> "bash"`, applies to every step) or **inline** on the command, which survives
> copy-pasting just the step: `FLOX_SHELL=bash flox activate -- make test`.

**3 — Read from a binary cache** (optional):
```yaml
env:                                          # non-secret; swap for your store
  S3_CACHE_BUCKET: "my-binary-cache"
  S3_CACHE_ENDPOINT: "https://<account>.r2.cloudflarestorage.com"
  S3_CACHE_REGION: "auto"
  S3_CACHE_PUBLIC_KEY: "my-cache-1:base64="
steps:
  - command: |
      source .buildkite/lib/s3-cache-load-secrets.sh   # creds from cluster secrets
      bash   .buildkite/lib/s3-cache-configure.sh       # point Nix at the cache (read)
      flox activate -- make test
```

**4 — Write back to the cache** (opt-in; needs the signing-key secret):
```yaml
env: { S3_CACHE_PUSH: "1" }                   # write-back is OFF by default
steps:
  - command: |
      # ...load-secrets, configure, activate...
      bash .buildkite/lib/s3-cache-push.sh    # no-op unless S3_CACHE_PUSH=1
```

## What to copy into your repo

| You want | Copy |
| --- | --- |
| Tier 0 (install per build) | `.buildkite/lib/linux-install-flox.sh` |
| Tier 1 — custom image | `.buildkite/agent-image/Dockerfile` |
| Tier 1 — `/nix` cache volume | `.buildkite/lib/ensure-nix.sh` + the `cache:` block in `pipeline.yml` |
| Binary cache | `.buildkite/lib/s3-cache-*.sh` |
| macOS | `.buildkite/lib/macos-*.sh` + `.buildkite/pipeline.macos.yml` |

Plus your `.flox/` environment and a pipeline `.yml` wiring the steps.

## Other platforms

- **macOS hosted** — same idea; the `.pkg` install is optimized to ~2s.
  → **[docs/macos.md](docs/macos.md)**
- **Self-hosted** — a reliably-warm `/nix` you own (local Docker example).
  → **[docs/self-hosted.md](docs/self-hosted.md)**

## What's optional

| Piece | Status |
| --- | --- |
| Install Flox (Tier 0) **or** custom image (Tier 1) | **Required** (one of them) |
| `flox activate` steps | **Required** |
| `/nix` cache volume · `SEED_PACKAGES` baking | *Optional* speed-ups |
| S3 binary cache | *Optional* integration |
| Cache write-back (`S3_CACHE_PUSH=1`) | *Optional*, off by default |

## Docs

Deep-dives in **[docs/](docs/README.md)**: [caching model](docs/caching-model.md)
· [hosted Linux (Tier 1)](docs/hosted-linux.md) · [S3 cache](docs/s3-cache.md) ·
[macOS](docs/macos.md) · [self-hosted](docs/self-hosted.md) ·
[automation](docs/automation.md) · [internals](docs/internals.md).

## Repo layout

```
.buildkite/
  pipeline.yml              worked Tier-1 example: install + activate (image + /nix volume + optional cache)
  pipeline.macos.yml        macOS hosted queue (zstd fast install + optional cache)
  agent-image/Dockerfile    Tier-1 custom agent image: Flox + SEED_PACKAGES + /opt/nix-seed
  lib/
    linux-install-flox.sh   Tier 0: install Flox per build on a generic Linux agent
    ensure-nix.sh           seed the /nix cache volume from /opt/nix-seed when cold
    s3-cache-*.sh           binary cache: load-secrets, configure (read), push (write), read-proof
    macos-*.sh              macOS install + S3 helpers (fast install, daemon-auth)
    diagnostics/            opt-in measurement scripts (not used by normal builds)
  examples/                 copy-ready / demo pipelines (minimal, s3-cache, self-hosted, region-discovery)
scripts/bk-setup.sh         optional: create the pipeline + secrets via an authed bk CLI
self-hosted/                run a self-hosted agent locally (reliably warm /nix)
.flox/                      a small Flox env whose `hello` package is this repo's CI smoke-test sentinel
docs/                       deep-dives
```
