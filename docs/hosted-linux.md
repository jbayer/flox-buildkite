# Tier 1 — faster installs on hosted Linux (custom image + cache volume)

[← docs index](README.md) · [← main README](../README.md)

Tier 0 (install Flox per build, see the README) works on any Linux queue with
zero setup, but it pays the install each build. Two independent speed-ups remove
that cost:

| Speed-up | Where it lives | What it buys |
| --- | --- | --- |
| **Custom agent image** | `.buildkite/agent-image/Dockerfile` — installs Flox + `SEED_PACKAGES` into `/nix/store`, then stashes a copy at `/opt/nix-seed` | Flox present on **every** build, zero per-build install. |
| **`/nix` cache volume** | `.buildkite/examples/pipeline.cached.yml` declares the volume; `.buildkite/lib/ensure-nix.sh` seeds it when cold | Persists whatever a build pulled into `/nix`, so later builds reuse it. |

This is the Buildkite equivalent of GitHub's `flox/install-flox-action` (install)
+ `actions/cache` on `/nix` (warm store), done once at the image/queue level. Use
either or both.

## The seed pattern (caching `/nix`)

Combining the two has a catch: a cache volume mounted at `/nix` is **empty on the
first build**, which *shadows* the `/nix` baked into the agent image and turns
`/usr/bin/flox` into a dangling symlink → `flox: command not found`.

The **seed pattern** resolves this:

1. **Image** (`agent-image/Dockerfile`): after installing Flox, stash a copy of
   the baked store outside `/nix` — `RUN cp -al /nix /opt/nix-seed` (hardlinked,
   so it costs ~no extra image space). `/opt` is not shadowed by the volume.
2. **Volume** (`examples/pipeline.cached.yml`): mount the cache volume at `/nix`.
3. **Seed on cold** (`lib/ensure-nix.sh`, called at the top of each Flox step):
   if `/usr/bin/flox` isn't executable (dangling → cold volume), copy
   `/opt/nix-seed` into `/nix`, restoring a working Flox. On a warm volume it's a
   no-op. **Call it once per job** — on hosted agents each step is a separate job
   that may land on a different agent with its own cold volume.

After a build, the volume holds Flox **and** the env's packages that
`flox activate` pulled, so a *warm* later build skips both the seed copy and the
package downloads.

## Best-effort, not durable

Buildkite hosted-agent cache volumes are **best-effort accelerators, not durable
storage** ([docs](https://buildkite.com/docs/pipelines/hosted-agents/cache-volumes)).
A job that exits `0` commits a new volume version ("last write" model), but the
next build is **only re-attached to that volume on a best-effort basis depending
on locality** — "back-to-back builds don't reliably reuse the same volume." So:

- **Low-frequency pipelines see mostly cold mounts.** Each build tends to land on
  a fresh instance without your committed copy → `Mounted cache on /nix (size
  4.0K)` → the seed runs. Hit rate rises with build frequency but is never
  guaranteed.
- That's *why* the seed pattern exists: every cold mount restores itself instead
  of failing. Warm hits are not guaranteed.

**Reading the log:**
- `Mounted cache on /nix (size <large>)` + `--- /nix cache volume is warm …
  skipping seed` → warm hit (fast).
- `Mounted cache on /nix (size 4.0K)` + `+++ cold … seeding from /opt/nix-seed`
  → cold mount; expect a seed copy + (for a large env) a closure download.

**If you need *reliable* warmth** (not best-effort): bake the env into the agent
image (rebuild on manifest change), add an [S3 binary cache](s3-cache.md), or use
[self-hosted](self-hosted.md) agents whose disk persists `/nix` naturally.

## Baking common packages (`SEED_PACKAGES`)

To make even cold builds fast for heavy, common dependencies (language runtimes,
compilers, toolchains), **bake them into the image** — they then live in
`/opt/nix-seed` and land in `/nix` on every cold seed, so `flox activate` finds
them already present.

Edit the `SEED_PACKAGES` arg in `agent-image/Dockerfile` (space-separated Flox
pkg-paths) and rebuild the image:

```dockerfile
ARG SEED_PACKAGES="nodejs python3 go"      # or "nodejs@20 rustc cargo gcc", etc.
```

The build runs `flox install $SEED_PACKAGES` to realize those closures into the
store before stashing the seed. This is **reliable** (unlike the volume) because
it's part of the image — at the cost of rebuilding the image when the list
changes.

**Caveat:** a baked package only produces a runtime cache hit when a project env
resolves to the *same* store path (same version from the same catalog). Bake the
versions your projects actually use, or you'll bake one version and download
another.

## Single-user Flox in the container

The agent container has no `systemd`/`nix-daemon`, so the image sets
`NIX_REMOTE=auto`, which makes Nix operate on the store directly as the job's
user. Because Buildkite chooses the job's user and forbids changing
`USER`/`UID`/`GID` in the Dockerfile, the image makes `/nix` writable
(`chmod -R a+rwX /nix`) instead of chowning it to a user we create.

## Runbook — register the image and queue

1. **Know your queue's architecture.** A Linux hosted queue is either **arm64**
   or **amd64** — the Dockerfile auto-detects via `uname -m`, so no edits are
   needed. No queue? Agents → cluster → **New Queue** → **Buildkite hosted** →
   Linux → pick the architecture.
2. **Create the custom agent image.** Agents → cluster → **Agent Images** → **New
   Image**, name `flox-agent`. The `FROM` line is **pre-filled by Buildkite and
   cannot be edited** (it pins `buildkite/hosted-agent-base` for the queue's
   arch). Paste `agent-image/Dockerfile` **minus its `FROM` line**. (Edit
   `SEED_PACKAGES` first if you want to bake packages.) Create — the final
   `RUN flox --version` proves the install works.
3. **Attach it to the queue.** Agents → cluster → **Queues** → your Linux queue →
   **Base image** → select `flox-agent` → Save.
4. **Point the pipeline at the cached example** to use the `/nix` volume (Steps:
   `buildkite-agent pipeline upload .buildkite/examples/pipeline.cached.yml`) and
   run a build. (The plain `.buildkite/pipeline.yml` also works on the image —
   it just doesn't add the volume.)

> ⚠️ The Dockerfile carries the `/opt/nix-seed` stash, so if you enable the cache
> volume after a first attempt, **rebuild the `flox-agent` image** first.

### Observe warm vs cold

Run a few builds and watch the `Mounted cache on /nix (size …)` line and
`ensure-nix.sh`'s warm/cold message. On a low-frequency pipeline you'll see
**mostly cold mounts** — documented best-effort behavior, not a misconfiguration.
Warm-hit rate climbs as the pipeline runs more often; the seed keeps every cold
mount working in the meantime.

## Caveats

- A cache volume on `/nix` conflicts with baking Flox into the image — use the
  seed pattern above, not a plain volume.
- Cache volumes are **best-effort**, ~14-day retention — treat `/nix` caching as
  an optimization, never a dependency. Cold builds still work (re-download).
- One cache volume per step.
- Pin `FLOX_VERSION` in the Dockerfile for reproducible agent images.
- If a step prints `NO: /nix not writable`, that's the one thing to tune in the
  Dockerfile for your queue's job user.

## Where hosted agents run (and why the S3 cache region matters)

Buildkite hosted agents run in a US East Coast **private cloud** — not AWS/GCP/
Azure. Empirically, a hosted Linux job egresses from **Northern Virginia**
(Leesburg, VA; IATA `iad`) on **Namespace** (`nscluster.cloud`, ASN `AS401483`),
and the AWS/GCP/Azure metadata endpoints answer nothing.

Why it matters: when the cache volume isn't re-attached (a cold mount), the
fallback is to re-fetch the closure from upstream. The mitigation is an
[S3-compatible binary cache](s3-cache.md) that lives **close to `iad` /
`us-east-1`** so cold builds pull from nearby storage at low latency. Buildkite
notes the egress ranges can change, so re-check the location if cold pulls slow.
