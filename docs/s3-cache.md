# S3-compatible binary cache (Nix substituter)

[← docs index](README.md) · [← main README](../README.md)

An **optional integration** that composes with Tier 0 *or* Tier 1. The `/nix`
cache volume is best-effort and the agent image only bakes a *fixed* seed.
Neither reliably holds **what a given build actually produced**. A binary cache —
a Nix *substituter* — does: every build reads from it, and (opt-in) writes back.

Works with **any S3-compatible object store**: AWS S3, CloudFlare R2, MinIO,
Ceph RGW, Backblaze B2, … You supply a bucket, an endpoint URL, a region, and
credentials. **This repo's example was tested against CloudFlare R2** (chosen for
**zero egress fees** — a binary cache is read-heavy — and for sitting close to the
hosted agents' egress region, `iad` / `us-east-1`), but nothing is R2-specific.

It works because Flox shells out to its own bundled Nix, which reads
`/etc/nix/nix.conf` — so an `extra-substituters` line there makes a cold
`flox activate` **pull prebuilt paths from the cache** instead of from upstream.

```
S3 BINARY CACHE — read on cold builds; write-back is opt-in
────────────────────────────────────────────────────────────────────────────
   flox activate ──▶ path in /nix?  ──no──▶ S3 substituter? ──hit──▶ pull   ✅
                                                  └─miss─▶ upstream (cold)  ⏳
   each build (opt-in) ──▶ s3-cache-push.sh writes its env closure back ─────┘
                           so the NEXT cold build finds it warm in the cache
```

## Read and write

| Half | Script | What it does |
| --- | --- | --- |
| **Read** (default) | `lib/s3-cache-load-secrets.sh` + `lib/s3-cache-configure.sh` | Load creds, then idempotently add the cache `extra-substituters` + trusted public key to `/etc/nix/nix.conf`. Inputs are **non-secret** — you can bake them into the agent image instead (the `S3_CACHE_*` ARGs in `agent-image/Dockerfile`). |
| **Write** (opt-in) | `lib/s3-cache-push.sh` | Signs and pushes the activated env's closure (`$FLOX_ENV`) — or explicit store paths — with `nix copy --to s3://…`. No-op unless `S3_CACHE_PUSH=1`. |

`.buildkite/examples/pipeline.s3-cache.yml` runs the whole round-trip in one
step: configure (read) → `flox activate` → push back (write) → read-proof.

## Configuration knobs

Non-secret, set in the pipeline `env:` block (or the Dockerfile ARGs):

| Var | Meaning | Example |
| --- | --- | --- |
| `S3_CACHE_BUCKET` | bucket name | `flox-binary-cache` |
| `S3_CACHE_ENDPOINT` | full S3 endpoint URL | R2: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` · AWS: `https://s3.us-east-1.amazonaws.com` · MinIO: `https://minio.example.com:9000` |
| `S3_CACHE_REGION` | region (default `auto`) | R2: `auto` · AWS/MinIO: a real region, e.g. `us-east-1` |
| `S3_CACHE_PUBLIC_KEY` | the cache's trusted public key | `flox-binary-cache-1:base64=` |
| `S3_CACHE_PUSH` | write-back toggle (default `0` = read-only) | `1` = also push closures (needs the signing key) |

## One-time setup

1. **Bucket + S3 credentials.** Create a bucket and an **S3 access key** (Access
   Key ID + Secret Access Key) with read+write to it.
   - *CloudFlare R2:* an R2 **API token** with *Object Read & Write* scoped to the
     bucket — S3-compatible, yields the key pair; endpoint
     `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, region `auto`.
   - *AWS S3:* an IAM access key with `s3:GetObject`/`PutObject`/`ListBucket`;
     endpoint `https://s3.<region>.amazonaws.com`, region your bucket's region.
   - *MinIO/Ceph:* an access/secret key pair; endpoint your server URL.
2. **Signing keypair** (only needed if you enable write-back). A cache must sign
   paths so other machines trust them:
   ```bash
   nix --extra-experimental-features nix-command key generate-secret \
       --key-name flox-binary-cache-1 > secret.key
   nix --extra-experimental-features nix-command key convert-secret-to-public \
       < secret.key > public.key
   ```
   `public.key` is the non-secret `S3_CACHE_PUBLIC_KEY`. `secret.key`'s **text**
   is the secret `S3_CACHE_SIGNING_KEY`.

## Wiring it on Buildkite

Set these as **cluster secrets** (Agents → cluster → Secrets); fetched at runtime
via `buildkite-agent secret get`, never baked into the image:

| Secret | Value |
| --- | --- |
| `S3_CACHE_ACCESS_KEY_ID` / `S3_CACHE_SECRET_ACCESS_KEY` | the S3 access key pair |
| `S3_CACHE_SIGNING_KEY` | the **text** of `secret.key` (write-back only) |

The non-secret `S3_CACHE_*` vars live in the pipeline `env:` block. See the
[building blocks](../README.md#pipeline-building-blocks) for the step snippets.

## Private vs public reads

The setup above keeps the bucket **private**: reads go through `s3://` and every
agent needs the access key. To read **without credentials**, expose the bucket
over a public HTTPS URL (R2's **r2.dev** domain, an AWS S3 website/CloudFront URL,
a MinIO public bucket, …) and use it as a plain `https://` substituter — writes
still use the authenticated `s3://` push. Store paths are content-addressed build
artifacts, so a public-read cache is the norm (it's how `cache.nixos.org` works);
the trade-off is the cache contents become world-readable.

## Guard the signing key

The S3 access key controls bucket access, but the **signing key** is the
credential that matters most: anyone holding it can place *trusted* paths in your
cache. Keep it only in Buildkite secrets (and a secure local copy), never in the
image or the repo. `s3-cache-push.sh` writes it to a `0600` temp file and deletes
it on exit.

> Verified against a real **CloudFlare R2** bucket: signed push, signature-checked
> cold pull, and a `flox install` that fetched a package from the cache as the
> *only* substituter. The same code path works against any other S3-compatible
> store by changing the endpoint/region.
