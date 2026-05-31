# The caching model (mental model)

[← docs index](README.md) · [← main README](../README.md)

**Flox and every package it installs live under a single directory,
`/nix/store`.** (`/usr/bin/flox` is itself just a symlink into it.) So making
CI fast reduces to one thing: **have as much of `/nix/store` already present as
possible when a build starts**, instead of downloading it mid-build.

```
   flox activate ──▶ needs its packages present in /nix/store
                       ├─ already there?  →  instant       ✅
                       └─ missing?        →  download it    ⏳  ← the cost to minimize
```

Two things make `/nix/store` warm: (1) **installing Flox faster** (Tier 0 → Tier 1
in the README), and (2) **a binary cache** so missing paths come from nearby
storage instead of upstream.

## Hosted agents — layers fill `/nix/store`, with a clear fallback order

You don't own the machine, so you stack independent caching layers. When a
build needs a `/nix` path, it's resolved in this order — each layer caught
before the slower one below it:

```
HOSTED AGENTS — where a needed /nix path comes from, in fallback order
────────────────────────────────────────────────────────────────────

Baked into the custom agent image (Tier 1)                 [ RELIABLE ]
   │  the image installs Flox + commonly used packages into /nix/store
   │  at image-build time.
   └▶ present on EVERY build, guaranteed, zero per-build install.

   then, for anything not already in /nix:

  1. /nix cache volume            present?  →  use it        [ BEST-EFFORT ]
        persists what past builds pulled, BUT re-attach depends on
        locality — often cold / not re-attached.
              │ cold / not attached?  the first place to check next ↓
  2. S3 binary cache (your bucket)  hit?    →  pull (near, signed)  [ DURABLE ]
        lives close to the agents (iad / us-east-1); builds can also
        write their closure back (opt-in) so later cold builds find it warm.
              │ miss?  flows up to ↓
  3. Flox / upstream binary cache   hit?    →  pull        [ ALWAYS WORKS ]
        cache.flox.dev, cache.nixos.org — the furthest, slowest hop.
```

The image bake (if you use one) is always present. The volume only helps when a
build lands back on the same one — so **when it's cold, the S3 cache is the next
stop**, and only a miss *there* flows up to the upstream Flox/Nix binary cache.

## Self-hosted agents — you control the storage

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

See also: [Hosted Linux internals](hosted-linux.md) · [S3 binary cache](s3-cache.md)
· [Self-hosted](self-hosted.md).
