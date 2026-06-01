# Automated setup with the `bk` CLI

[← docs index](README.md) · [← main README](../README.md)

The agent image and queue base-image are Buildkite **UI** steps, but the rest is
scriptable with an authenticated [`bk` CLI](https://github.com/buildkite/cli):

```bash
flox install buildkite-cli
bk configure --org <org> --token <token>   # token: Personal Settings -> API Access Tokens
bk cluster list                            # find your cluster's UUID
ORG=<org> CLUSTER_UUID=<uuid> REPO=<git-url> PIPELINE=flox-buildkite \
  ./scripts/bk-setup.sh --build
```

`scripts/bk-setup.sh`:
- creates the pipeline (Buildkite runs the repo's `.buildkite/pipeline.yml` by
  default — no steps to set);
- prints the `bk secret create` commands for the **optional** S3 cache;
- with `--build`, triggers **and watches** a first build.

Flags: `--no-s3` (skip the cache reminder), `--webhook` (also set up the GitHub
webhook).

## Prerequisites can't be pre-checked

The `flox-agent` image and the queue's base-image are **not exposed by `bk` or
the REST API** (no `bk` command; the REST `agent-images` endpoint 401s). So a
**green build is the prerequisite check** — that's what `--build` is for. If a
build stalls with no agents or `flox: not found`, the image/queue UI steps aren't
done yet.

## Driving builds from a headless machine

`bk` 3.x stores its token in the system keyring, which a headless box may lack.
The Buildkite **REST API** needs no keyring — drive builds with `curl` + a token
in a file:

```bash
TOK="$(cat ~/.bk-token)"
# create a build
curl -sS -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  https://api.buildkite.com/v2/organizations/<org>/pipelines/<pipeline>/builds \
  -d '{"commit":"HEAD","branch":"main","env":{"FAST_INSTALL":"1"}}'
# poll a build's state
curl -sS -H "Authorization: Bearer $TOK" \
  https://api.buildkite.com/v2/organizations/<org>/pipelines/<pipeline>/builds/<n> | jq -r .state
```

The token needs `write_builds` (create) + `read_builds`/`read_pipelines`
(poll/log). Cluster/agent-image endpoints need additional scopes the build token
may not have.
