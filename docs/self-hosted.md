# Self-hosted agents (a reliably warm `/nix`)

[← docs index](README.md) · [← main README](../README.md)

Hosted agents have a best-effort `/nix` cache volume. If you run **self-hosted**
agents you control the disk, so `/nix` can persist **reliably**, without depending
on locality. The `self-hosted/` directory runs one as a local Docker container so
you can see it end to end.

**How it stays warm:** the agent runs as a long-lived container with a Docker
**named volume** mounted at `/nix`. On first `up`, Docker copies the image's baked
`/nix` (Flox + `SEED_PACKAGES`) into the empty volume, so Flox works immediately —
and the volume persists across builds *and* `docker compose restart`. The simple
`.buildkite/pipeline.yml` runs as-is — `linux-install-flox.sh` no-ops (the image
already has Flox) and `flox activate` finds the warm `/nix`. `examples/pipeline.cached.yml`
also works (its hosted-only `cache:` block is ignored and `ensure-nix.sh` becomes
a no-op on the already-warm volume); `pipeline.self-hosted.yml` is the tailored one.

**S3 cache on a `/nix` miss.** The volume makes `/nix` reliably warm, but a
brand-new runner, a wiped volume, or a path the env newly needs is still a *miss*.
`pipeline.self-hosted.yml` wires in the same [S3 binary cache](s3-cache.md): on a
miss, `flox activate` substitutes from it before going upstream, and (with
`S3_CACHE_PUSH=1`) writes its closure back so a fresh runner repopulates fast. The
self-hosted image makes `/etc/nix/nix.conf` writable so the runtime configure step
works even when the base agent image runs jobs as a non-root user.

## Run it locally

```bash
cd self-hosted
cp .env.example .env          # then paste your token (Agents -> cluster -> Agent Tokens)
docker compose up --build     # builds the agent image and connects it to Buildkite
```

The agent registers under the queue tag `flox-self-hosted`. Point your pipeline's
**Steps** at the self-hosted pipeline (in `.buildkite/examples/`):

```yaml
steps:
  - command: buildkite-agent pipeline upload .buildkite/examples/pipeline.self-hosted.yml
```

Trigger a build, then a **second** one: the first populates `/nix`, and every
build after — including after `docker compose restart` — finds it already warm.
Confirm persistence directly:

```bash
docker volume inspect flox-buildkite-self-hosted_nix-store
docker compose exec agent du -sh /nix
```

## When to prefer self-hosted vs hosted

- **Hosted + cache volume + seed:** zero infra to run; warm cache is best-effort.
- **Self-hosted + persistent `/nix`:** you run the agent, but the warm cache is
  reliable and there's no per-build seed copy. Best when a large closure makes
  consistent warmth worth operating an agent.
