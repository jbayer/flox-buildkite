# flox-buildkite

Test repository for running [Flox](https://flox.dev) on [Buildkite](https://buildkite.com)
hosted agents, fast and reproducibly.

## The approach

Two costs make Flox slow in CI, and they need separate fixes:

| Cost | Fix here |
| --- | --- |
| Installing Flox (binary + Nix) every build | **Bake Flox into a custom agent image** — `.buildkite/agent-image/Dockerfile`. Flox is simply present; no per-build install. |
| Populating the Nix store (downloading the env closure) | **Cache volume on `/nix`** — declared in `.buildkite/pipeline.yml`. First build is cold; later builds reuse a warm store. |

This is the Buildkite equivalent of GitHub's `flox/install-flox-action` (install) +
`actions/cache` on `/nix` (warm store), but done once at the image/queue level
instead of per-workflow.

## Layout

```
.buildkite/
  agent-image/Dockerfile   custom hosted-agent image with Flox preinstalled
  pipeline.yml             validation + activation steps, /nix cache volume
.flox/                     a small Flox environment (jq + hello) to activate
```

## One-time setup

1. **Build & register the agent image.** Build `.buildkite/agent-image/Dockerfile`
   and push it to the Buildkite internal container registry, or paste it into the
   Dockerfile editor in the Buildkite UI.
   - Default arch is **aarch64** (arm64 queue). For an amd64 queue, build with
     `--build-arg FLOX_ARCH=x86_64`.
2. **Point the queue at it.** In your cluster's queue settings: **Base image** tab
   → **Agent image** → select the image → save.
3. **Run the pipeline.** `.buildkite/pipeline.yml` validates the runtime user and
   `/nix` permissions, then activates the env and times it.

## How Flox runs single-user in the container

The agent container has no `systemd`/`nix-daemon`, so the image sets
`NIX_REMOTE=auto`, which makes Nix operate on the store directly as the job's
user. Because Buildkite chooses the job's user and forbids changing
`USER`/`UID`/`GID` in the Dockerfile, the image makes `/nix` writable
(`chmod -R a+rwX /nix`) rather than chowning it to a user we create.

## Using it in real pipelines

Run any command inside the environment with:

```yaml
steps:
  - command: flox activate -- <your command>
```

Or activate once for every step via an agent `environment` hook.

## Caveats

- Cache volumes are **best-effort**, ~14-day retention — treat `/nix` caching as
  an optimization, never a dependency. Cold builds still work (re-download).
- One cache volume per step.
- Pin `FLOX_VERSION` in the Dockerfile for reproducible agent images.
