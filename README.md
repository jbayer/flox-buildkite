# flox-buildkite

How to run [Flox](https://flox.dev) on [Buildkite](https://buildkite.com)
— both **hosted** and **self-hosted** agents — fast and reproducibly, with
minimal per-build install required.

## How the caching works (the mental model)

**Flox and every package it installs live under a single directory,
`/nix/store`.** (`/usr/bin/flox` is itself just a symlink into it.) So making
CI fast reduces to one thing: **have as much of `/nix/store` already present as
possible when a build starts**, instead of downloading it mid-build.

```
   flox activate ──▶ needs its packages present in /nix/store
                       ├─ already there?  →  instant       ✅
                       └─ missing?        →  download it    ⏳  ← the cost to minimize
```

### Hosted agents — layers fill `/nix/store`, with a clear fallback order

You don't own the machine, so you stack independent caching layers. When a
build needs a `/nix` path, it's resolved in this order — each layer caught
before the slower one below it:

```
HOSTED AGENTS — where a needed /nix path comes from, in fallback order
────────────────────────────────────────────────────────────────────

PHASE 1 · baked into the CI base image                     [ RELIABLE ]
   │  The custom agent image installs Flox + commonly used runtime
   │  packages into /nix/store at image-build time.
   └▶ present on EVERY build, guaranteed, zero per-build install.

   then, for anything not already in /nix:

  1. /nix cache volume            present?  →  use it        [ BEST-EFFORT ]
        persists what past builds pulled, BUT re-attach depends on
        locality — often cold / not re-attached.
              │ cold / not attached?  the first place to check next ↓
  2. S3 binary cache (your bucket)  hit?    →  pull (near, signed)  [ DURABLE ]
        lives close to the agents (iad / us-east-1); each build also
        writes its closure back, so the next cold build finds it warm.
              │ miss?  flows up to ↓
  3. Flox / upstream binary cache   hit?    →  pull        [ ALWAYS WORKS ]
        cache.flox.dev, cache.nixos.org — the furthest, slowest hop.
```

Phase 1 is always present. The volume only helps when a build lands back on the
same one — so **when it's cold, the S3 cache is the next stop**, and only a miss
*there* flows up to the upstream Flox/Nix binary cache. The standard
`pipeline.yml` wires in layers 2–3 (see *Durable cache* below); the S3 cache is
optional — clear `S3_CACHE_BUCKET` to run on just the volume.

### Self-hosted agents — you control the storage

On your own infrastructure you place `/nix/store` — and an optional backup cache
layer — right next to the runners, so reuse is predictable.

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

---

# Buildkite hosted agents

On hosted agents you don't own the machine, so you make `/nix/store` fast with
the two phases above: bake Flox into the custom agent image, and lean on a
best-effort cache volume. The **Linux** flow is below; **macOS** hosted agents
work differently and have their own subsection at the end.

## How the two phases map to this repo

| Phase | Where it lives |
| --- | --- |
| **1 · bake into the image** | `.buildkite/agent-image/Dockerfile` — installs Flox + `SEED_PACKAGES` into `/nix/store`, then stashes a copy at `/opt/nix-seed` (the seed pattern, below) |
| **2 · cache volume on `/nix`** | `.buildkite/pipeline.yml` declares the volume; `.buildkite/lib/ensure-nix.sh` seeds it when cold |

This is the Buildkite equivalent of GitHub's `flox/install-flox-action`
(install) + `actions/cache` on `/nix` (warm store), done once at the
image/queue level.

## The seed pattern (caching `/nix`)

Combining the two phases has a catch: a cache volume mounted at `/nix` is
**empty on the first build**, which *shadows* the `/nix` baked into the agent
image and turns `/usr/bin/flox` into a dangling symlink →
`flox: command not found`.

The **seed pattern** resolves this:

1. **Image** (`agent-image/Dockerfile`): after installing Flox, stash a copy
   of the baked store outside `/nix` — `RUN cp -al /nix /opt/nix-seed`
   (hardlinked, so it costs ~no extra image space). `/opt` is not shadowed by
   the volume.
2. **Volume** (`pipeline.yml`): mount the cache volume at `/nix`.
3. **Seed on cold** (`lib/ensure-nix.sh`, called at the top of each Flox step):
   if `/usr/bin/flox` isn't executable (dangling → cold volume), copy
   `/opt/nix-seed` into `/nix`, restoring a working Flox. On a warm volume
   it's a no-op.

After a build, the volume holds Flox **and** the env's packages that
`flox activate` pulled, so a *warm* later build skips both the seed copy and the
package downloads.

## Best-effort, not durable

Buildkite hosted-agent cache volumes are **best-effort accelerators, not durable
storage** ([docs](https://buildkite.com/docs/pipelines/hosted-agents/cache-volumes)).
A job that exits `0` commits a new volume version ("last write" model), but the
next build is **only re-attached to that volume on a best-effort basis depending
on locality** — "back-to-back builds don't reliably reuse the same volume." So:

- **Low-frequency pipelines see mostly cold mounts.** Each build tends to
  land on a fresh instance without your committed copy
  → `Mounted cache on /nix (size 4.0K)` → the seed runs. Hit rate rises with
  build frequency but is never guaranteed.
- That's *why* the seed pattern exists: every cold mount restores itself instead
  of failing. Warm hits are not guaranteed.

**Reading the log:**
- `Mounted cache on /nix (size <large>)` + `--- /nix cache volume is warm …
  skipping seed` → warm hit (fast).
- `Mounted cache on /nix (size 4.0K)` + `+++ cold … seeding from /opt/nix-seed`
  → cold mount; expect a seed copy + (for a large env) a closure download.

**If you need *reliable* warmth** (not best-effort): bake the env into the agent
image (rebuild on manifest change), or use **self-hosted** agents whose disk
persists `/nix` naturally. On hosted agents the volume is the best available,
and it's worth it only when the env closure is large enough that re-downloading
it costs more than the ~seconds the seed adds.

## Where hosted agents run

Buildkite hosted agents run in a US East Coast **private cloud** — not AWS/GCP/
Azure. `.buildkite/pipeline.region-discovery.yml` confirms this empirically: a
hosted Linux job egresses from **Northern Virginia** (Leesburg, VA; IATA `iad`)
on **Namespace** (`nscluster.cloud`, ASN `AS401483`), and the AWS/GCP/Azure
metadata endpoints answer nothing.

Why it matters: when the cache volume isn't re-attached (a cold mount), the
fallback is to re-fetch the closure from upstream. The mitigation is a
**layered, S3-compatible binary cache** (a Nix substituter) — and it should
live **close to `iad` / `us-east-1`** so cold builds pull from nearby storage
at low latency. Re-run the region-discovery pipeline to re-check the location,
since Buildkite notes the egress ranges can change.

## Baking common packages (`SEED_PACKAGES`)

The cache volume is best-effort, so cold mounts happen. To make even cold builds
fast for the heavy, common dependencies (language runtimes, compilers,
toolchains), **bake them into the image** — they then live in `/opt/nix-seed`
and land in `/nix` on every cold seed, so `flox activate` finds them already
present.

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

## Single-user Flox in the container

The agent container has no `systemd`/`nix-daemon`, so the image sets
`NIX_REMOTE=auto`, which makes Nix operate on the store directly as the job's
user. Because Buildkite chooses the job's user and forbids changing
`USER`/`UID`/`GID` in the Dockerfile, the image makes `/nix` writable
(`chmod -R a+rwX /nix`) instead of chowning it to a user we create.

This was verified locally as a non-root user with `NIX_REMOTE=auto`:
`flox activate` works and the `hello` package binary runs. The on-Buildkite
confirmation is the runbook below.

## Runbook (Linux)

The end-to-end setup for a Linux hosted queue.

### Prerequisite — know your queue's architecture

You need a Buildkite **cluster** with a **Linux hosted queue** (either **arm64**
or **amd64** — the Dockerfile auto-detects the architecture, so no edits are
needed for either). No queue yet? Agents → cluster → **New Queue** → **Buildkite
hosted** → Linux → pick the architecture.

### Step 1 — Create the custom agent image

1. Global nav → **Agents** → select your cluster.
2. **Agent Images** tab → **New Image**.
3. **Name:** `flox-agent`.
4. **Dockerfile field:** the `FROM` line is **pre-filled by Buildkite and
   cannot be edited** (it pins `buildkite/hosted-agent-base` for the queue's
   arch). Paste `.buildkite/agent-image/Dockerfile` **minus its `FROM` line**.
   No arch edits needed — the Flox install auto-detects `x86_64` vs `aarch64`
   via `uname -m`.
   - To bake common packages (language runtimes, etc.) into the store, edit the
     `SEED_PACKAGES` arg before creating the image — see *Baking common
     packages* above.
5. **Create Agent Image.** Buildkite builds it; the final `RUN flox --version`
   means a successful build already proves the install works.

### Step 2 — Attach the image to the queue

1. Agents → cluster → **Queues** → select your Linux hosted queue.
2. **Base image** tab → **Agent image** dropdown → select **flox-agent**.
3. **Save settings.**

### Step 3 — Create the pipeline

1. Global nav → **Pipelines** → **New Pipeline**.
2. **Repository:** `https://github.com/jbayer/flox-buildkite` (authorize GitHub
   access if prompted — the repo is private).
3. **Cluster/Queue:** select the cluster and queue from Step 2.
4. **Steps:** use the upload step from `.buildkite/upload.yml` (Buildkite's
   default is already equivalent). This uploads the real steps from
   `.buildkite/pipeline.yml`.
5. Create Pipeline.

### Step 4 — Run the first build (the acceptance test)

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

✅ That's the acceptance test: **`flox activate` works and a real package
binary runs.**

The step runs `flox activate -- hello`. `hello` is the **smoke-test sentinel**
pinned in `.flox/env/manifest.toml` — the single source of truth for what the
pipeline can run. The agent images' `SEED_PACKAGES` mirror it only to keep that
binary *warm*; they never decide whether it's available (the manifest does), so
changing `SEED_PACKAGES` can't break the test.

> ⚠️ The Dockerfile carries the `/opt/nix-seed` stash, so if you enabled caching
> after a first attempt, **rebuild the `flox-agent` image** before this build.

### Step 5 — Observe warm vs cold (don't expect every build to be warm)

Run a few builds and watch the `Mounted cache on /nix (size …)` line and
`ensure-nix.sh`'s warm/cold message:

- **Warm hit:** `size <large>` + `… cache volume is warm … skipping seed`, and a
  faster `time flox activate` (no seed, no closure download).
- **Cold mount:** `size 4.0K` + `+++ cold … seeding from /opt/nix-seed`.

⚠️ On a low-frequency pipeline you'll see **mostly cold mounts** — this is the
documented best-effort behavior, not a misconfiguration (see *Best-effort, not
durable* above). Consecutive builds often land on different agent instances and
so don't share the volume. Warm-hit rate climbs as the pipeline runs more often;
the seed keeps every cold mount working in the meantime.

### Using Flox in real pipelines

Run any command inside the environment with:

```yaml
steps:
  - command: flox activate -- <your command>
```

…or activate once for every step via an agent `environment` hook.

## Caveats

These concern the **Linux** hosted flow above — the `/nix` cache volume, the
seed pattern, and the agent image. (macOS differs; see below.)

- A cache volume on `/nix` conflicts with baking Flox into the image — see
  *The seed pattern* above. Use the seed pattern, not a plain volume.
- Cache volumes are **best-effort**, ~14-day retention — treat `/nix` caching
  as an optimization, never a dependency. Cold builds still work (re-download).
- One cache volume per step.
- Pin `FLOX_VERSION` in the Dockerfile for reproducible agent images.
- If the validate step prints `NO: /nix not writable`, that's the one thing to
  tune in the Dockerfile for your queue's job user.

## macOS hosted agents

Buildkite's **macOS** hosted agents work differently from Linux, so Flox is set
up differently — see `.buildkite/pipeline.macos.yml`, which runs the helper
`.buildkite/lib/macos-install-flox.sh`. This flow is verified working on the
built-in `macos-medium` queue. Two constraints drive the approach:

- **No custom agent images.** Unlike Linux, you can't bake Flox into the base
  image, so Flox comes from its macOS `.pkg`. The stock `installer -pkg` is ~42s
  — and a breakdown showed that's almost entirely **single-threaded xz
  decompression** of the Nix store (the store itself is tiny: 324 MB, ~12k files,
  ~1s with zstd). So `macos-install-flox.sh` uses a **fast install** (on by
  default; `FAST_INSTALL=0` to disable):
  - **Bootstrap** (first build on a fresh cache volume): run the `.pkg` once, then
    cache `/nix` as a **zstd** archive on the persistent `/tmp/flox-cache` volume.
  - **Fast path** (every build after): create a real `/nix` APFS volume
    (`diskutil addVolume`, ~0.6s), **zstd-restore the store** (~1s), and run Nix
    **single-user** — a mode the flox installer supports (no daemon, no `nixbld`
    users), so `/nix` is owned by the job user just like Linux. **~42s → ~2s.**
    If the fast path ever fails, it cleans up and falls back to the `.pkg`.

  Single-user also means the **S3 read uses the job's own creds** (no root daemon),
  so the fast path skips the `/var/root` daemon-auth dance entirely. (`macos-s3-
  daemon-auth.sh` is still used on the `.pkg`/`FAST_INSTALL=0` multi-user path.)
- **`/nix` is a system APFS volume with a daemon.** macOS Nix is multi-user
  only, so you can't bind-mount a cache volume over `/nix` as on Linux. Warmth,
  when you need it, comes from a Nix **binary cache / substituter**, not from
  caching the `/nix` mount.

### Wiring it to a Mac

The link to a macOS VM is the step's queue tag. `pipeline.macos.yml` targets
**`macos-medium`**, a built-in Buildkite hosted macOS queue, so it routes to a
real queue out of the box (swap it for a larger shape like `macos-large` if you
need more resources). To run it, point a pipeline's **Steps** at the file:

```yaml
steps:
  - command: buildkite-agent pipeline upload .buildkite/pipeline.macos.yml
```

The `pipeline upload` runs on whatever queue handles the build's first step
(any queue — it only parses YAML); the install/activate step then dispatches to
`macos-medium` via its `agents: { queue: "macos-medium" }` tag. If the build
stalls at the upload step, the pipeline's default queue has no agents — set that
default to `macos-medium` too, or let an existing queue handle the upload.

What the example pipeline does:

1. **Checks for passwordless sudo** and fails fast if it's missing. The `.pkg`
   creates the `/nix` APFS volume, the `nix-daemon`, and `nixbld` users — all of
   which need root. `macos-medium` grants it; the `sudo -n true` probe stays as
   a guard so a queue that doesn't fails with a clear message instead of midway.
2. **Installs the pinned `.pkg`**, caching the download on a best-effort cache
   volume so re-installs skip it:
   `sudo installer -pkg flox-$FLOX_VERSION.aarch64-darwin.pkg -target /`.
3. **Puts `flox` on `PATH`** and runs the same sentinel as the other queues:
   `flox activate -- hello`. flox is self-contained, so no Nix daemon profile
   needs sourcing.

For the activate to work on macOS, the repo env must list `aarch64-darwin` in
`.flox/env/manifest.toml` `[options] systems` (added) with a regenerated
lockfile that includes it.

The honest trade-off vs Linux: macOS loses image baking, so Flox can't be made
install-free there — only install-fast (cache the `.pkg`) and closure-warm.

**Closure warmth comes from the S3 binary cache**, wired into
`pipeline.macos.yml` (there is no `/nix` cache volume on macOS). It uses the same
`S3_CACHE_*` config and cluster secrets as the hosted/​self-hosted pipelines, but
with a macOS-specific twist for the **read** path:

- macOS Nix is **multi-user**, so the **root `nix-daemon`** — not the job —
  performs substitute downloads, and the job's S3 token never reaches it.
  `macos-s3-daemon-auth.sh` therefore writes the token to root's
  `~/.aws/credentials` (where the daemon's `aws-sdk` looks) and **restarts the
  daemon** so it reloads the substituter that `s3-cache-configure.sh` added to
  `/etc/nix/nix.conf`.
- The **write-back** is client-side and works like Linux (uses the job's token).
  Because macOS Nix's `curl` (OpenSSL) has **no default CA bundle**, the client
  would fail with `curlCode 60` ("unable to get local issuer certificate"); the
  script sets `NIX_SSL_CERT_FILE` to a CA bundle so the push works.
- The read setup is **non-fatal**: on any macOS quirk it logs a warning and
  `flox activate` falls back to upstream, so it can't break a working build.
  flox hides the substituter source, so the clearest proof the cache is wired is
  the **write-back** (`+++ pushing … to s3://…` → `--- push complete`) at the end
  of the step.

> ✅ Verified on a real macOS hosted build (`macos-medium`): daemon label
> auto-discovered as `org.nixos.nix-daemon`, restart + reload worked, and
> `flox activate` succeeded. The first run surfaced a client-side `curlCode 60`
> TLS failure on the push — fixed by setting `NIX_SSL_CERT_FILE` (above).

---

# Durable cache: an S3-compatible binary cache (Nix substituter)

The `/nix` cache volume is best-effort and the agent image only bakes a *fixed*
seed. Neither reliably holds **what a given build actually produced**. The
durable layer that does is an **S3-compatible Nix binary cache** — a
*substituter* — that every build reads from and writes back to.

This works with **any S3-compatible object store**: AWS S3, CloudFlare R2,
MinIO, Ceph RGW, Backblaze B2, and so on. You only supply a bucket, an endpoint
URL, a region, and credentials. **This repo's example was tested against
CloudFlare R2** (chosen for **zero egress fees** — a binary cache is read-heavy
— and for sitting close to the hosted agents' egress region, `iad` /
`us-east-1`), but nothing here is R2-specific; point it at your own store.

It works because Flox shells out to its own bundled Nix, which reads
`/etc/nix/nix.conf` — so an `extra-substituters` line there makes a cold
`flox activate` **pull prebuilt paths from the cache** instead of from upstream.

```
S3 BINARY CACHE — the durable layer, read on cold builds, written on every build
────────────────────────────────────────────────────────────────────────────
   flox activate ──▶ path in /nix?  ──no──▶ S3 substituter? ──hit──▶ pull   ✅
                                                  └─miss─▶ upstream (cold)  ⏳
   each build ──▶ s3-cache-push.sh writes its env closure back to the cache ┘
                  so the NEXT cold build finds it warm in the cache
```

## Two halves: read and write

| Half | Script | What it does |
| --- | --- | --- |
| **Read** | `.buildkite/lib/s3-cache-configure.sh` | Idempotently adds the cache `extra-substituters` + trusted public key to `/etc/nix/nix.conf`. Inputs are **non-secret**, so you can bake them into the agent image instead (`agent-image/Dockerfile`, the `S3_CACHE_*` ARGs). |
| **Write** | `.buildkite/lib/s3-cache-push.sh` | Signs and pushes the activated env's closure (`$FLOX_ENV`) — or explicit store paths — to the cache with `nix copy --to s3://…`. |

`.buildkite/pipeline.s3-cache.yml` runs the whole round-trip in one step:
**configure (read) → `flox activate` → push back (write) → read-proof**.

## Configuration knobs

Non-secret, set in the pipeline `env:` block (or the Dockerfile ARGs):

| Var | Meaning | Example |
| --- | --- | --- |
| `S3_CACHE_BUCKET` | bucket name | `flox-binary-cache` |
| `S3_CACHE_ENDPOINT` | full S3 endpoint URL | R2: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` · AWS: `https://s3.us-east-1.amazonaws.com` · MinIO: `https://minio.example.com:9000` |
| `S3_CACHE_REGION` | region (default `auto`) | R2: `auto` · AWS/MinIO: a real region, e.g. `us-east-1` |
| `S3_CACHE_PUBLIC_KEY` | the cache's trusted public key | `flox-binary-cache-1:base64=` |

## One-time setup

1. **Bucket + S3 credentials.** Create a bucket on your provider and an
   **S3 access key** (Access Key ID + Secret Access Key) with read+write to it.
   - *CloudFlare R2:* create an R2 **API token** with *Object Read & Write*
     scoped to the bucket — it's S3-compatible and yields the key pair above;
     the endpoint is `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, region `auto`.
   - *AWS S3:* an IAM access key with `s3:GetObject`/`PutObject`/`ListBucket`;
     endpoint `https://s3.<region>.amazonaws.com`, region your bucket's region.
   - *MinIO/Ceph:* an access/secret key pair; endpoint your server URL.
2. **Signing keypair.** A cache must sign paths so other machines trust them:
   ```bash
   nix --extra-experimental-features nix-command key generate-secret \
       --key-name flox-binary-cache-1 > secret.key
   nix --extra-experimental-features nix-command key convert-secret-to-public \
       < secret.key > public.key
   ```
   `public.key` is the non-secret `S3_CACHE_PUBLIC_KEY` (goes in nix.conf / the
   pipeline `env:`). `secret.key`'s **text** is the secret `S3_CACHE_SIGNING_KEY`.

## Wiring it on Buildkite

Set these as **cluster secrets** (Agents → cluster → Secrets); they're fetched
at runtime via `buildkite-agent secret get` and never baked into the image:

| Secret | Value |
| --- | --- |
| `S3_CACHE_ACCESS_KEY_ID` / `S3_CACHE_SECRET_ACCESS_KEY` | the S3 access key pair |
| `S3_CACHE_SIGNING_KEY` | the **text** of `secret.key` |

The non-secret `S3_CACHE_BUCKET`, `S3_CACHE_ENDPOINT`, `S3_CACHE_REGION`,
`S3_CACHE_PUBLIC_KEY` live in the pipeline `env:` block (swap them for yours).
Point a pipeline's **Steps** at it:

```yaml
steps:
  - command: buildkite-agent pipeline upload .buildkite/pipeline.s3-cache.yml
```

## Private vs public reads

The setup above keeps the bucket **private**: reads go through `s3://` and every
agent needs the access key in its environment. If you'd rather agents read
**without credentials**, expose the bucket over a public HTTPS URL (R2's
**r2.dev** domain, an AWS S3 website/CloudFront URL, a MinIO public bucket, …)
and use it as a plain `https://` substituter — writes still use the
authenticated `s3://` push. Store paths are content-addressed build artifacts,
so a public-read cache is the norm (it's how `cache.nixos.org` works); the
trade-off is the cache contents become world-readable.

## Guard the signing key

The S3 access key controls bucket access, but the **signing key** is the
credential that matters most: anyone holding it can place *trusted* paths in
your cache. Keep it only in Buildkite secrets (and a secure local copy), never
in the image or the repo. `s3-cache-push.sh` writes it to a `0600` temp file and
deletes it on exit.

> Verified locally on this container against a real **CloudFlare R2** bucket
> (the example values above): signed push, cold-store pull with signature
> checking, and a `flox install` that fetched a package from the cache as the
> *only* substituter. The write-back step pushes the `environment-develop`
> closure so the next cold build can substitute it. The same code path works
> against any other S3-compatible store by changing the endpoint/region.

---

# Self-hosted agents (a reliably warm `/nix`)

Everything above is for Buildkite *hosted* agents, where the `/nix` cache
volume is best-effort. If you run **self-hosted** agents you control the disk,
so `/nix` can persist **reliably**, without depending on locality. The
`self-hosted/` directory runs one as a local Docker container so you can see it
end to end.

How it stays warm: the agent runs as a long-lived container with a Docker
**named volume** mounted at `/nix`. On first `up`, Docker copies the image's
baked `/nix` (Flox + `SEED_PACKAGES`) into the empty volume, so Flox works
immediately — and the volume persists across builds *and*
`docker compose restart`. The steps run unchanged from the hosted setup:
`pipeline.self-hosted.yml` needs no `cache:` block, and even the hosted
`pipeline.yml` works as-is because its `cache:` block is a hosted-agent
directive self-hosted agents ignore and `ensure-nix.sh` becomes a no-op on the
already-warm volume.

**S3 cache on a `/nix` miss.** The volume makes `/nix` reliably warm, but a
brand-new runner, a wiped volume, or a path the env newly needs is still a
*miss*. `pipeline.self-hosted.yml` wires in the same S3 binary cache as
layer 2 (the *backup cache layer* in the diagram above): on a miss, `flox
activate` substitutes from the S3 cache before going upstream, and each build
pushes its closure back so a fresh runner repopulates fast. It uses the same
cluster secrets as the hosted pipeline and is optional — clear `S3_CACHE_BUCKET`
to run on just the persistent volume. The self-hosted image makes
`/etc/nix/nix.conf` writable so the runtime configure step works even when the
base agent image runs jobs as a non-root user.

## Run it locally

```bash
cd self-hosted
cp .env.example .env          # then paste your token (Agents -> cluster -> Agent Tokens)
docker compose up --build     # builds the agent image and connects it to Buildkite
```

The agent registers under the queue tag `flox-self-hosted`. Point your
pipeline's **Steps** (Pipeline → Settings → Steps) at the version-controlled
self-hosted pipeline, which targets that queue:

```yaml
steps:
  - label: ":pipeline: upload"
    command: buildkite-agent pipeline upload .buildkite/pipeline.self-hosted.yml
```

Trigger a build, then trigger a **second** one: the first populates `/nix`, and
every build after — including after `docker compose restart` — finds it
already warm (instant activate, no download). Confirm persistence directly:

```bash
docker volume inspect flox-buildkite-self-hosted_nix-store
docker compose exec agent du -sh /nix
```

## When to prefer self-hosted vs hosted

- **Hosted + cache volume + seed:** zero infra to run; warm cache is
  best-effort.
- **Self-hosted + persistent `/nix`:** you run the agent, but the warm cache is
  reliable and there's no per-build seed copy. Best when a large closure makes
  consistent warmth worth operating an agent.

---

# Repo layout

```
.buildkite/
  agent-image/Dockerfile          hosted Linux agent image: Flox + SEED_PACKAGES + /opt/nix-seed
  pipeline.yml                    hosted Linux steps: validate + activate, with the /nix volume + S3 cache (layers 1-3)
  pipeline.self-hosted.yml        steps for the self-hosted queue (warm-/nix check + S3 cache on a /nix miss)
  pipeline.macos.yml              steps for a macOS hosted queue (per-build .pkg install)
  pipeline.region-discovery.yml   informational: print a hosted Linux agent's egress IP + region
  pipeline.s3-cache.yml           S3 binary-cache round-trip: configure read + activate + push back + read-proof
  lib/ensure-nix.sh               seeds the /nix cache volume from /opt/nix-seed when cold
  lib/s3-cache-load-secrets.sh    source to load S3 cache secrets into the job (no-op when S3_CACHE_BUCKET empty)
  lib/s3-cache-configure.sh       READ path: add the S3 cache substituter + trusted key to /etc/nix/nix.conf
  lib/s3-cache-push.sh            WRITE path: sign + push the env closure (or given paths) to the S3 cache
  lib/s3-cache-read-proof.sh      deterministic read check: pull the env closure back from the cache, sigs required
  lib/macos-install-flox.sh       macOS: fast (zstd) or .pkg install of Flox, wires the S3 cache, activates
  lib/macos-fast-install.sh       macOS fast install: bootstrap a zstd /nix archive + restore it single-user (~2s)
  lib/macos-s3-daemon-auth.sh     macOS (.pkg/multi-user path): give the root nix-daemon S3 creds + restart it
  lib/region-discovery.sh         prints egress IP/ASN/geo; probes cloud metadata endpoints
  upload.yml                      the one-line pipeline-upload step for Buildkite settings
self-hosted/                      run a self-hosted agent locally (reliably warm /nix)
  Dockerfile                      buildkite-agent + Flox
  docker-compose.yml              agent + persistent /nix named volume
  .env.example                    where the agent token goes
.flox/                            a small Flox environment whose `hello` package is the
                                  CI smoke-test sentinel (single source of truth)
```
