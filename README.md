# flox-buildkite

How to run [Flox](https://flox.dev) on [Buildkite](https://buildkite.com)
— both **hosted** and **self-hosted** agents — fast and reproducibly, with
minimal per-build install required.

## How the caching works (the mental model)

With Flox and Nix, **everything lives in a single directory, `/nix/store`.** 
Flox itself, every language runtime, every package — all of it. 
(`/usr/bin/flox` is just a symlink into `/nix/store`.) So "make CI fast" 
reduces to one thing: **have as much of `/nix/store` already present as 
possible when a build starts**, instead of downloading it mid-build.

```
   flox activate ──▶ needs its packages present in /nix/store
                       ├─ already there?  →  instant       ✅
                       └─ missing?        →  download it    ⏳  ← the cost to minimize
```

### Hosted agents — two phases fill `/nix/store`

You don't own the machine, so you stack two independent caching layers:

```
HOSTED AGENTS — two phases keep /nix/store full before a build runs
────────────────────────────────────────────────────────────────────

PHASE 1 · bake into the CI base image                      [ RELIABLE ]
   │  The custom agent image installs Flox + commonly used runtime
   │  packages into /nix/store at image-build time.
   └▶ present on EVERY build, guaranteed, zero per-build install.

                              +

PHASE 2 · Buildkite cache volume on /nix                [ BEST-EFFORT ]
   │  A volume persists whatever a build pulled into /nix/store, so
   │  later builds reuse it instead of re-downloading.
   └▶ re-attach depends on locality — warmth is a bonus, not a promise.

                              ↓
   anything still missing is downloaded cold (slower, but always works)
```

Phase 1 is the floor — always there. Phase 2 raises the ceiling whenever builds
happen to land back on the same volume.

### Self-hosted agents — you control the storage

On your own infrastructure there's no locality lottery: you place `/nix/store`
— and an optional backup cache layer — right next to the runners.

```
SELF-HOSTED AGENTS — you own the disk, so warmth is RELIABLE
────────────────────────────────────────────────────────────────────

    agent runner (your infra)
         │  reads / writes
         ▼
    /nix/store on persistent storage you control           ← warm across
    (local disk or a mounted volume, next to the runner)      builds & restarts
         │  cold store or brand-new runner? repopulate fast from…
         ▼
    backup cache layer — an S3-compatible Nix binary cache near the runners

  You keep /nix/store and its backup close to the agents, so a build
  almost never has to download from upstream.
```

## The approach

The two hosted phases above map to specific files in this repo:

| Phase | Where it lives |
| --- | --- |
| **1 · bake into the image** | `.buildkite/agent-image/Dockerfile` — installs Flox + `SEED_PACKAGES` into `/nix/store`, then stashes a copy at `/opt/nix-seed` (the seed pattern, below) |
| **2 · cache volume on `/nix`** | `.buildkite/pipeline.yml` declares the volume; `.buildkite/lib/ensure-nix.sh` seeds it when cold |

This is the Buildkite equivalent of GitHub's `flox/install-flox-action` (install) +
`actions/cache` on `/nix` (warm store), done once at the image/queue level.

### Caching `/nix` (the seed pattern)

Combining the two phases has a catch: a cache volume mounted at `/nix` is
**empty on the first build**, which *shadows* the `/nix` baked into the agent
image and turns `/usr/bin/flox` into a dangling symlink → `flox: command not found`.

The **seed pattern** resolves this:

1. **Image** (`agent-image/Dockerfile`): after installing Flox, stash a copy of the
   baked store outside `/nix` — `RUN cp -al /nix /opt/nix-seed` (hardlinked, so it
   costs ~no extra image space). `/opt` is not shadowed by the volume.
2. **Volume** (`pipeline.yml`): mount the cache volume at `/nix`.
3. **Seed on cold** (`lib/ensure-nix.sh`, called at the top of each Flox step):
   if `/usr/bin/flox` isn't executable (dangling → cold volume), copy
   `/opt/nix-seed` into `/nix`, restoring a working Flox. On a warm volume it's a
   no-op.

After a build, the volume holds Flox **and** the env's packages that
`flox activate` pulled, so a *warm* later build skips both the seed copy and the
package downloads.

### Best-effort, not durable — read this before trusting the cache

Buildkite hosted-agent cache volumes are **best-effort accelerators, not durable
storage** ([docs](https://buildkite.com/docs/pipelines/hosted-agents/cache-volumes)).
A job that exits `0` commits a new volume version ("last write" model), but the
next build is **only re-attached to that volume on a best-effort basis depending
on locality** — "back-to-back builds don't reliably reuse the same volume." So:

- **Low-frequency pipelines see mostly cold mounts.** Each build tends to land on
  a fresh instance without your committed copy → `Mounted cache on /nix (size 4.0K)`
  → the seed runs. Hit rate rises with build frequency but is never guaranteed.
- That's *why* the seed pattern exists: every cold mount **self-heals** instead of
  failing. Warm hits are a bonus, not a contract.

**Reading the log:**
- `Mounted cache on /nix (size <large>)` + `--- /nix cache volume is warm … skipping
  seed` → warm hit (fast).
- `Mounted cache on /nix (size 4.0K)` + `+++ cold … seeding from /opt/nix-seed`
  → cold mount; expect a seed copy + (for a large env) a closure download.

**If you need *reliable* warmth** (not best-effort): bake the env into the agent
image (rebuild on manifest change), or use **self-hosted** agents whose disk
persists `/nix` naturally. On hosted agents the volume is the best available, and
it's worth it only when the env closure is large enough that re-downloading it
costs more than the ~seconds the seed adds.

### Baking common packages into the seed (`SEED_PACKAGES`)

The cache volume is best-effort, so cold mounts happen. To make even cold builds
fast for the heavy, common dependencies (language runtimes, compilers,
toolchains), **bake them into the image** — they then live in `/opt/nix-seed` and
land in `/nix` on every cold seed, so `flox activate` finds them already present.

Edit the `SEED_PACKAGES` arg in `agent-image/Dockerfile` (space-separated Flox
pkg-paths) and rebuild the image:

```dockerfile
ARG SEED_PACKAGES="nodejs python3 go"      # or "nodejs@20 rustc cargo gcc", etc.
```

The build runs `flox install $SEED_PACKAGES` to realize those closures into the
store before stashing the seed. This is **reliable** (unlike the volume) because
it's part of the image — at the cost of rebuilding the image when the list
changes. It complements the volume: baked packages cover cold mounts; the volume
additionally captures whatever each project env pulls at runtime.

**Caveat:** a baked package only produces a runtime cache hit when a project env
resolves to the *same* store path (same version from the same catalog). Bake the
versions your projects actually use, or you'll bake one version and download
another.

## Layout

```
.buildkite/
  agent-image/Dockerfile   custom hosted-agent image: Flox + SEED_PACKAGES + /opt/nix-seed
  pipeline.yml             real steps: validate + activate, with the /nix cache volume
  lib/ensure-nix.sh        seeds the /nix cache volume from /opt/nix-seed when cold
  upload.yml               the one-line pipeline-upload step for Buildkite settings
self-hosted/               run a self-hosted agent locally (reliably warm /nix)
  Dockerfile               buildkite-agent + Flox
  docker-compose.yml       agent + persistent /nix named volume
  .env.example             where the agent token goes
.flox/                     a small Flox environment whose `hello` package is the
                           CI smoke-test sentinel (single source of truth)
```

## How Flox runs single-user in the container

The agent container has no `systemd`/`nix-daemon`, so the image sets
`NIX_REMOTE=auto`, which makes Nix operate on the store directly as the job's
user. Because Buildkite chooses the job's user and forbids changing
`USER`/`UID`/`GID` in the Dockerfile, the image makes `/nix` writable
(`chmod -R a+rwX /nix`) instead of chowning it to a user we create.

This was verified locally as a non-root user with `NIX_REMOTE=auto`: `flox activate`
works and the `hello` package binary runs. The on-Buildkite confirmation is
the runbook below.

---

# Runbook

## Prerequisite — know your queue's architecture

You need a Buildkite **cluster** with a **Linux hosted queue** (either **arm64**
or **amd64** — the Dockerfile auto-detects the architecture, so no edits are
needed for either). No queue yet? Agents → cluster → **New Queue** → **Buildkite
hosted** → Linux → pick the architecture.

## Step 1 — Create the custom agent image

1. Global nav → **Agents** → select your cluster.
2. **Agent Images** tab → **New Image**.
3. **Name:** `flox-agent`.
4. **Dockerfile field:** the `FROM` line is **pre-filled by Buildkite and cannot
   be edited** (it pins `buildkite/hosted-agent-base` for the queue's arch). Paste
   `.buildkite/agent-image/Dockerfile` **minus its `FROM` line**. No arch edits
   needed — the Flox install auto-detects `x86_64` vs `aarch64` via `uname -m`.
   - To bake common packages (language runtimes, etc.) into the store, edit the
     `SEED_PACKAGES` arg before creating the image — see *Baking common packages*
     above.
5. **Create Agent Image.** Buildkite builds it; the final `RUN flox --version`
   means a successful build already proves the install works.

## Step 2 — Attach the image to the queue

1. Agents → cluster → **Queues** → select your Linux hosted queue.
2. **Base image** tab → **Agent image** dropdown → select **flox-agent**.
3. **Save settings.**

## Step 3 — Create the pipeline

1. Global nav → **Pipelines** → **New Pipeline**.
2. **Repository:** `https://github.com/jbayer/flox-buildkite` (authorize GitHub
   access if prompted — the repo is private).
3. **Cluster/Queue:** select the cluster and queue from Step 2.
4. **Steps:** use the upload step from `.buildkite/upload.yml` (Buildkite's default
   is already equivalent). This uploads the real steps from `.buildkite/pipeline.yml`.
5. Create Pipeline.

## Step 4 — Run the first build (the acceptance test)

Click **New Build** → Create Build on `main`, then check:

- **`:mag: validate agent + flox`** step →
  - `whoami` / `id` → runs as **root** on hosted agents
  - `NIX_REMOTE=auto`
  - `ensure-nix.sh` → `seeding from /opt/nix-seed` on the first build
  - `command -v flox` → `/usr/bin/flox`
  - `yes: /nix writable`
- **`:flox: activate environment`** step →
  - `Hello, world!` (GNU `hello`, the sentinel, ran)
  - exit **0**

✅ That's the acceptance test: **`flox activate` works and a real package binary runs.**

The step runs `flox activate -- hello`. `hello` is the **smoke-test sentinel**
pinned in `.flox/env/manifest.toml` — the single source of truth for what the
pipeline can run. The agent images' `SEED_PACKAGES` mirror it only to keep that
binary *warm*; they never decide whether it's available (the manifest does), so
changing `SEED_PACKAGES` can't break the test.

> ⚠️ The Dockerfile carries the `/opt/nix-seed` stash, so if you enabled caching
> after a first attempt, **rebuild the `flox-agent` image** before this build.

## Step 5 — Observe warm vs cold (don't expect every build to be warm)

Run a few builds and watch the `Mounted cache on /nix (size …)` line and
`ensure-nix.sh`'s warm/cold message:

- **Warm hit:** `size <large>` + `… cache volume is warm … skipping seed`, and a
  faster `time flox activate` (no seed, no closure download).
- **Cold mount:** `size 4.0K` + `+++ cold … seeding from /opt/nix-seed`.

⚠️ On a low-frequency pipeline you'll see **mostly cold mounts** — this is the
documented best-effort behavior, not a misconfiguration (see *Best-effort, not
durable* above). Consecutive builds often land on different agent instances and
so don't share the volume. Warm-hit rate climbs as the pipeline runs more often;
the seed makes every cold mount self-healing meanwhile.

## Using Flox in real pipelines

Run any command inside the environment with:

```yaml
steps:
  - command: flox activate -- <your command>
```

…or activate once for every step via an agent `environment` hook.

---

# Self-hosted agents (a reliably warm `/nix`)

Everything above is for Buildkite *hosted* agents, where the `/nix` cache volume
is best-effort. If you run **self-hosted** agents you control the disk, so `/nix`
can persist **reliably** — no locality lottery. The `self-hosted/` directory runs
one as a local Docker container so you can see it end to end.

How it stays warm: the agent runs as a long-lived container with a Docker **named
volume** mounted at `/nix`. On first `up`, Docker copies the image's baked `/nix`
(Flox + `SEED_PACKAGES`) into the empty volume, so Flox works immediately — and
the volume persists across builds *and* `docker compose restart`. The same
`.buildkite/pipeline.yml` runs unchanged; its `cache:` block is a hosted-agent
directive that self-hosted agents simply ignore, and `ensure-nix.sh` becomes a
no-op because the volume is already warm.

## Run it locally

```bash
cd self-hosted
cp .env.example .env          # then paste your token (Agents -> cluster -> Agent Tokens)
docker compose up --build     # builds the agent image and connects it to Buildkite
```

The agent registers under the queue tag `flox-self-hosted`. Point a pipeline step
at it:

```yaml
steps:
  - label: ":flox: activate"
    agents: { queue: "flox-self-hosted" }
    command: flox activate -- hello
```

Trigger a build, then trigger a **second** one: the first populates `/nix`, and
every build after — including after `docker compose restart` — finds it already
warm (instant activate, no download). Confirm persistence directly:

```bash
docker volume inspect flox-buildkite-self-hosted_nix-store
docker compose exec agent du -sh /nix
```

## When to prefer self-hosted vs hosted

- **Hosted + cache volume + seed:** zero infra to run; warm cache is best-effort.
- **Self-hosted + persistent `/nix`:** you run the agent, but the warm cache is
  reliable and there's no per-build seed copy. Best when a large closure makes
  consistent warmth worth operating an agent.

## Caveats

- A cache volume on `/nix` conflicts with baking Flox into the image — see
  *Caching `/nix`* above. Use the seed pattern, not a plain volume.
- Cache volumes are **best-effort**, ~14-day retention — treat `/nix` caching as an
  optimization, never a dependency. Cold builds still work (re-download).
- One cache volume per step.
- Pin `FLOX_VERSION` in the Dockerfile for reproducible agent images.
- If the validate step prints `NO: /nix not writable`, that's the one thing to tune
  in the Dockerfile for your queue's job user.
