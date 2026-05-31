# Docs

Deep-dives for [flox-buildkite](../README.md). Start with the main README's
quick start and building blocks; reach for these when you want the *why* or are
turning on a specific feature.

| Doc | When you want it |
| --- | --- |
| [Caching model](caching-model.md) | The mental model: how `/nix/store` is kept warm, and the fallback order. |
| [Hosted Linux (Tier 1)](hosted-linux.md) | Faster installs via a custom agent image and/or a `/nix` cache volume — the seed pattern, `SEED_PACKAGES`, the runbook. |
| [S3 binary cache](s3-cache.md) | The optional durable cache: setup, signing keys, private vs public reads, config knobs. |
| [macOS](macos.md) | macOS hosted agents: the zstd fast install (~42s→~2s) and the S3 specifics. |
| [Self-hosted](self-hosted.md) | A reliably-warm `/nix` you own (local Docker example). |
| [Automation (`bk`)](automation.md) | Scripting setup + driving builds with the `bk` CLI / REST API. |
| [Internals](internals.md) | Why it's built this way — the investigations behind the design. |
