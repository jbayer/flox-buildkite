# flox-buildkite

Test repository for running [Flox](https://flox.dev) on [Buildkite](https://buildkite.com)
hosted agents — fast, reproducibly, with no per-build install.

## The approach

Two things make Flox slow in CI, and they need separate fixes:

| Cost | Fix here |
| --- | --- |
| Installing Flox (binary + Nix) every build | **Bake Flox into a custom agent image** — `.buildkite/agent-image/Dockerfile`. Flox is simply present; zero per-build install. |
| Populating the Nix store (downloading the env closure) | Warm-caching `/nix` across builds — **deliberately not enabled yet** (see *Caching `/nix`* below); it conflicts with baking Flox into the image and needs the seed pattern. |

This is the Buildkite equivalent of GitHub's `flox/install-flox-action` (install),
done once at the image/queue level instead of per-workflow.

### Caching `/nix` (why it's not a plain cache volume)

Flox and its bundled Nix live entirely under `/nix/store` — `/usr/bin/flox` is just
a symlink into `/nix`. A cache volume mounted at `/nix` is **empty on the first
build**, so it *shadows* the `/nix` baked into the agent image, turning
`/usr/bin/flox` into a dangling symlink → `flox: command not found`.

So with Flox baked into the image you **cannot** also cache-mount `/nix` naively.
To get warm cross-build caching you need the **seed pattern**: copy the baked store
aside in the image (`RUN cp -a /nix /opt/nix-seed`), mount the cache volume at
`/nix`, and in a pre-command hook seed the volume from `/opt/nix-seed` when it's
empty. That's a follow-up; the current setup keeps Flox baked-in and skips the
`/nix` volume so the basic path is correct first.

## Layout

```
.buildkite/
  agent-image/Dockerfile   custom hosted-agent image with Flox preinstalled
  pipeline.yml             real steps: validate + activate (no /nix cache volume yet)
  upload.yml               the one-line pipeline-upload step for Buildkite settings
.flox/                     a small Flox environment (jq + hello) to activate
```

## How Flox runs single-user in the container

The agent container has no `systemd`/`nix-daemon`, so the image sets
`NIX_REMOTE=auto`, which makes Nix operate on the store directly as the job's
user. Because Buildkite chooses the job's user and forbids changing
`USER`/`UID`/`GID` in the Dockerfile, the image makes `/nix` writable
(`chmod -R a+rwX /nix`) instead of chowning it to a user we create.

This was verified locally as a non-root user with `NIX_REMOTE=auto`: `flox activate`
works and package binaries (`hello`, `jq`) run. The on-Buildkite confirmation is
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
  - `whoami` / `id` (the real job user — the one open question)
  - `NIX_REMOTE=auto`
  - `flox --version` → `1.12.1`
  - `yes: /nix writable`
- **`:flox: activate environment`** step →
  - `Hello, world!` (GNU `hello` ran)
  - `jq-1.8.1`
  - exit **0**

✅ That's the acceptance test: **`flox activate` works and a real package binary runs.**

## Step 5 — (later) warm caching

Cross-build `/nix` caching is intentionally not enabled yet — see *Caching `/nix`*
above for why a plain cache volume breaks the baked-in Flox, and the seed pattern
that does it correctly. Get Step 4 green first.

## Using Flox in real pipelines

Run any command inside the environment with:

```yaml
steps:
  - command: flox activate -- <your command>
```

…or activate once for every step via an agent `environment` hook.

## Caveats

- A cache volume on `/nix` conflicts with baking Flox into the image — see
  *Caching `/nix`* above. Use the seed pattern, not a plain volume.
- Cache volumes are **best-effort**, ~14-day retention — treat `/nix` caching as an
  optimization, never a dependency. Cold builds still work (re-download).
- One cache volume per step.
- Pin `FLOX_VERSION` in the Dockerfile for reproducible agent images.
- If the validate step prints `NO: /nix not writable`, that's the one thing to tune
  in the Dockerfile for your queue's job user.
