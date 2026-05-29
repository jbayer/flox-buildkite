# flox-buildkite

Test repository for running [Flox](https://flox.dev) on [Buildkite](https://buildkite.com)
hosted agents — fast, reproducibly, with no per-build install.

## The approach

Two things make Flox slow in CI, and they need separate fixes:

| Cost | Fix here |
| --- | --- |
| Installing Flox (binary + Nix) every build | **Bake Flox into a custom agent image** — `.buildkite/agent-image/Dockerfile`. Flox is simply present; zero per-build install. |
| Populating the Nix store (downloading the env closure) | **Cache volume on `/nix`** — declared in `.buildkite/pipeline.yml`. First build is cold; later builds reuse a warm store. |

This is the Buildkite equivalent of GitHub's `flox/install-flox-action` (install) +
`actions/cache` on `/nix` (warm store), done once at the image/queue level instead
of per-workflow.

## Layout

```
.buildkite/
  agent-image/Dockerfile   custom hosted-agent image with Flox preinstalled
  pipeline.yml             real steps: validate + activate, with /nix cache volume
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

You need a Buildkite **cluster** with a **Linux hosted queue**. Note whether that
queue is **arm64** or **amd64** (Agents → cluster → Queues → the queue shows its
architecture). It must match `FLOX_ARCH` in the Dockerfile (`aarch64` for arm64,
`x86_64` for amd64). No queue yet? Agents → cluster → **New Queue** → **Buildkite
hosted** → Linux → pick the architecture.

## Step 1 — Create the custom agent image

1. Global nav → **Agents** → select your cluster.
2. **Agent Images** tab → **New Image**.
3. **Name:** `flox-agent`.
4. **Dockerfile field:** the `FROM` line is **pre-filled by Buildkite and cannot
   be edited** (it pins `buildkite/hosted-agent-base` for the queue's arch). Paste
   `.buildkite/agent-image/Dockerfile` **minus its `FROM` line**.
   - ⚠️ The UI builds the Dockerfile as-is (no `--build-arg`), so the **`FLOX_ARCH`
     default value is what's used** — set it to `x86_64` if your queue is amd64.
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

## Step 5 — Confirm the cache warms

Run **New Build** again and compare the `time flox activate` output: build #2 should
be faster than #1 because the `/nix` cache volume already holds the store closure.

## Using Flox in real pipelines

Run any command inside the environment with:

```yaml
steps:
  - command: flox activate -- <your command>
```

…or activate once for every step via an agent `environment` hook.

## Caveats

- Cache volumes are **best-effort**, ~14-day retention — treat `/nix` caching as an
  optimization, never a dependency. Cold builds still work (re-download).
- One cache volume per step.
- Pin `FLOX_VERSION` in the Dockerfile for reproducible agent images.
- If the validate step prints `NO: /nix not writable`, that's the one thing to tune
  in the Dockerfile for your queue's job user.
