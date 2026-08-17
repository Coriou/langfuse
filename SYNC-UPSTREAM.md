# Keeping Your Fork in Sync

This document explains how to keep your `custom` branch in sync with the upstream Langfuse repository while preserving your Docker Compose modifications for Coolify.

## Overview

Your `custom` branch contains modifications to `docker-compose.yml` that make Langfuse work better with Coolify:
- Commented out localhost-bound ports (ClickHouse, Redis, PostgreSQL)
- Modified MinIO console port binding
- Simplified PostgreSQL environment variables
- Explicit version pins on every image
- ClickHouse config overrides in `clickhouse-config-d/`

These changes are maintained on top of the latest upstream code using git rebase.

## Read this before syncing

Four things will bite you if you sync on autopilot. **`sync-upstream.sh` now enforces
the first three itself** — they are documented here because you still need to
understand what it is protecting you from, and because the manual process below has
no such guardrails.

**1. Upstream is on v4; this deployment is deliberately on the v3 line.** The script
will *not* cross a major version implicitly. Its default target is the highest tag
within the major line the branch is currently based on (detected via
`git describe --tags --abbrev=0`). If a newer major exists it says so and declines:

```
🏷️  Target: v3.225.3 — highest tag in the current v3 line (commit f6c77b7)
ℹ️  Upstream's newest release is v4.11.0, deliberately NOT chosen:
    crossing a major version requires --allow-major or --tag v4.11.0.
```

Moving to v4 is a deliberate act requiring `--allow-major` or an explicit
`--tag v4.x.y`. Do not add either to a scheduled job.

**2. Not every upstream git tag has a published image.** We deploy prebuilt images, so
a git tag with no corresponding build is not deployable. `v3.225.3` is exactly this
case: the tag exists, but neither `langfuse/langfuse:sha-f6c77b7` nor `:3.225.3` was
ever pushed to Docker Hub or ghcr.io.

The script now runs a registry preflight against **both** `langfuse/langfuse` and
`langfuse/langfuse-worker` before it rewrites anything, and aborts with the newest
usable tag as a suggestion:

```
🔍 Registry preflight for sha-f6c77b7 (need linux/arm64):
   ❌ langfuse/langfuse:sha-f6c77b7 — NOT PUBLISHED (registry 404)
   ❌ langfuse/langfuse-worker:sha-f6c77b7 — NOT PUBLISHED (registry 404)
   👉 Newest tag in this line that IS published for linux/arm64: v3.225.2
```

To check a tag by hand (e.g. for ClickHouse or MinIO, which the script does not
manage):

```bash
docker manifest inspect docker.io/langfuse/langfuse:sha-<7char>
docker manifest inspect docker.io/langfuse/langfuse-worker:sha-<7char>
```

Never sync the source tree to a version you cannot actually run — that just makes the
docs assert something untrue.

**3. The deployment host is ARM — check the architecture, not just the tag.**
`apps.coriou.net` is aarch64 (Hetzner ARM). An amd64-only image is a **hard blocker**
here, not a slow fallback: it will not run at all. The script's preflight requires
`linux/arm64` in the manifest platform list and aborts if it is missing (override the
expected platform with `REQUIRED_PLATFORM=` if this ever moves off ARM).

For images the script does not manage — ClickHouse and MinIO — check by hand:

```bash
docker manifest inspect docker.io/<image>:<tag> \
  | jq -r '.manifests[].platform | .os + "/" + .architecture'
```

All four currently pinned images publish both `linux/amd64` and `linux/arm64`.

**4. `clickhouse-config-d/` is repo-owned.** Coolify re-materialises that directory
from git on every deploy, so anything edited directly on the host is silently reverted
the next time you deploy. This has already cost us once: `memory_limits.xml` lived
only on the server, and any deploy would have wiped it and reinstated a ClickHouse
OOM crash-loop. Make changes here, commit them, then deploy.

## Open tracking item: v3.225.3

**Status as of 2026-08-17: skipped, deliberately. Re-check on the next sync.**

`v3.225.3` (commit `f6c77b70`) is a real upstream git tag, newer than the `v3.225.2`
this branch is built on, but **no container image was ever published for it** —
`langfuse/langfuse:sha-f6c77b7` and `:3.225.3` are both absent from Docker Hub and
ghcr.io. On its release date upstream built only 4.10.0, so the v3 backport release
appears to have been tagged without a corresponding image build.

It contains exactly two security backports:

| Fix | Upstream PR |
|---|---|
| SCIM: ignore the `password` attribute in user provisioning | #16027 |
| API: validate `authorUserId` on public comment creation | #16026 |

Neither looks likely to apply to this deployment — SCIM provisioning is an enterprise
feature we are almost certainly not using, and the second needs the public comment
surface to be in use. **But "probably not applicable" is a reason to defer, not to
forget.** Both fixes ship inside the image, so they are unreachable until upstream
publishes one.

**On the next sync:** you no longer need to remember this — `./sync-upstream.sh` will
resolve `v3.225.3` as the default target, run the registry preflight, fail closed, and
report that `v3.225.2` is the newest usable tag. If an image has since appeared the
preflight passes and the sync proceeds normally; delete this section when it does. If
v3 has moved on past 3.225.3 by then, verify the newer tag carries both fixes.
Do not build the image locally — an unofficial image has no place in this deployment
path.

## Quick Sync (Automated)

```bash
./sync-upstream.sh --dry-run     # always start here: prints the full plan, changes nothing
./sync-upstream.sh               # then run it for real
```

The script will:
1. Offer to stash uncommitted changes, then check you're on the `custom` branch
2. Fetch upstream (branches and tags)
3. Detect the major line the branch is currently based on
4. Resolve a target tag — **highest tag in the current major line**, never crossing a
   major implicitly
5. **Registry preflight**: abort unless both `langfuse/langfuse` and
   `langfuse/langfuse-worker` publish `sha-<target>` *and* it includes `linux/arm64`
6. Print the plan (current base → target, old image tag → new image tag, the upstream
   commits being picked up) and ask for confirmation
7. Rebase, preserving your Docker Compose modifications
8. **Automatically update SHA-based image tags** to match the new version and commit
9. Optionally restore your stashed changes, then remind you to force-push and to tag a
   rollback point first

### Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Print the whole plan and exit. Changes nothing. |
| `--yes`, `-y`, `--non-interactive` | Assume "yes" at every prompt. Safe for CI — the major-version and image guards still abort. |
| `--tag vX.Y.Z` | Rebase onto an exact tag. Deliberate, so it may cross a major. |
| `--main` | Rebase onto `upstream/main`. Needs `--allow-major` if that crosses a major. |
| `--allow-major` | Permit crossing to a higher major version. |
| `--skip-image-check` | Escape hatch that disables the registry preflight. This is the check that prevents rebasing onto an unbuildable tag — you almost never want this. |
| `--help` | Usage. |

Environment overrides: `UPSTREAM_REMOTE`, `WORK_BRANCH`, `COMPOSE_FILE`,
`REQUIRED_PLATFORM`.

Exit codes: `0` success or already up to date, `1` refused (major crossing, missing
image, wrong architecture, rebase conflict).

## Manual Sync Process

If you prefer to sync manually or need more control:

### 1. Fetch upstream changes

```bash
git fetch upstream --tags
```

### 2. Pick a target tag and check what's new

Stay on the v3 line — do **not** rebase onto `upstream/main`, which is v4 development.

```bash
git tag -l 'v3.*' | sort -V | tail -5     # newest v3 tags
git log --oneline --graph HEAD..v3.225.2  # what the bump brings in
```

### 3. Rebase on the chosen tag

```bash
git checkout custom
git rebase v3.225.2
```

### 4. Resolve conflicts (if any)

If there are conflicts in `docker-compose.yml`, you'll need to manually reapply your Coolify changes:

```bash
# After rebase, check what changed
git diff v3.225.2 docker-compose.yml

# Manually reapply Coolify modifications:
# - MinIO: docker.io/minio/minio pinned to a RELEASE.* tag, with curl healthcheck
# - ClickHouse: pinned to an explicit version, ./clickhouse-config-d mount intact
# - Comment out ports for ClickHouse, Redis, PostgreSQL
# - Remove Redis maxmemory-policy
# - Simplify PostgreSQL env vars

# After fixing
git add docker-compose.yml
git rebase --continue
```

### 5. Push to your fork

```bash
git push origin custom --force-with-lease
```

**Note**: `--force-with-lease` is safer than `--force` as it will fail if someone else pushed to your branch.

## Your Coolify-Specific Modifications

The following changes are maintained in your `custom` branch:

### MinIO
- Uses `docker.io/minio/minio` instead of `cgr.dev/chainguard/minio`
- Healthcheck uses `curl` instead of `mc ready local`
- Console port: `9091:9001` (not localhost-bound)
- Pinned to `RELEASE.2025-07-23T15-54-02Z`

### Langfuse Images
- Uses SHA-based tags (e.g., `sha-8ff44b6`) instead of version tags (`:3`)
- This pins deployments to specific builds for stability
- **The sync script automatically updates these SHAs** when syncing to a new version —
  but it does not verify the resulting image exists, so check it yourself

### ClickHouse
- Ports 8123, 9000 commented out (services connect internally)
- Pinned to `25.7.3.13`
- Config overrides mounted read-only from `./clickhouse-config-d/`

### Image pinning policy

All four images carry explicit version pins:

| Service | Pin |
|---|---|
| langfuse-web / langfuse-worker | `sha-8ff44b6` (v3.225.2) |
| clickhouse-server | `25.7.3.13` |
| minio | `RELEASE.2025-07-23T15-54-02Z` |

ClickHouse and MinIO used to float on `:latest` (ClickHouse carried no tag at all),
meaning a redeploy could silently pull a new major version with no commit to point at
when something broke. **Both are now deliberate bumps** — change the pin, verify the
tag exists with `docker manifest inspect`, confirm it publishes a `linux/arm64`
manifest (this host is ARM), and commit the bump on its own.

`redis:7` and `postgres:${POSTGRES_VERSION:-17}` still float within a major version.
That matches upstream's default and is a separate decision.

### Redis
- Port 6379 commented out (services connect internally)
- Removed `--maxmemory-policy noeviction` command flag

### PostgreSQL
- Simplified `POSTGRES_USER` to `postgres` (no env var fallback)
- Simplified `POSTGRES_DB` to `postgres` (no env var fallback)
- Removed `TZ` and `PGTZ` environment variables
- Port 5432 commented out (services connect internally)

### `clickhouse-config-d/` (repo-owned — not upstream)

Four override files mounted read-only into the ClickHouse container:
`memory_limits.xml`, `listen_host.xml`, `server_logging.xml`, `system_logs_ttl.xml`.

Upstream does not ship this directory, so it never conflicts during a rebase — but it
is also easy to forget it exists. Coolify rebuilds it from git on every deploy, so it
is the repo, not the server, that decides what ClickHouse runs with. See the
"Read this before syncing" section above.

## Troubleshooting

### Rebase conflicts

If you encounter conflicts during rebase:

1. Check which files have conflicts:
   ```bash
   git status
   ```

2. Open the conflicted files and resolve markers:
   - `<<<<<<< HEAD` - upstream version
   - `=======` - separator
   - `>>>>>>> <commit>` - your version

3. Choose to keep your Coolify modifications for the areas listed above

4. Continue the rebase:
   ```bash
   git add <resolved-files>
   git rebase --continue
   ```

5. If something goes wrong, you can always abort:
   ```bash
   git rebase --abort
   ```

### Verify your changes

After syncing, verify only your intended changes remain:

```bash
git diff v3.225.2 docker-compose.yml
```

This should only show your Coolify-specific modifications.

## Git Remote Configuration

Your repository should have two remotes:

```bash
git remote -v
# origin    git@github.com:Coriou/langfuse.git (your fork)
# upstream  git@github.com:langfuse/langfuse.git (original repo)
```

If upstream is not configured:

```bash
git remote add upstream git@github.com:langfuse/langfuse.git
```

## Branch Strategy

- `main` - tracks upstream/main directly (fast-forward only)
- `custom` - your Coolify modifications rebased on top of latest upstream
- Deploy `custom` to your Coolify instance

## Regular Sync Workflow

We recommend syncing regularly (e.g., weekly or before important updates):

```bash
# 1. See what a sync would do — no changes, and it will refuse anything unsafe
./sync-upstream.sh --dry-run

# 2. Tag a rollback point at the CURRENT remote state before rewriting anything
git fetch origin
git tag custom-pre-$(date -u +%Y%m%d) origin/custom
git push origin custom-pre-$(date -u +%Y%m%d)

# 3. Run the sync (rebases, verifies images, bumps the sha- tags, commits)
./sync-upstream.sh

# 4. Test locally if possible
docker compose up -d

# 5. Push to your fork — rebase workflow, so this must be forced
git push origin custom --force-with-lease

# 5. Deploy to Coolify (triggers automatically if configured)
```

## Need Help?

If you encounter issues or the rebase becomes too complex:

1. Abort the current rebase: `git rebase --abort`
2. Create a backup of your changes: `git branch custom-backup`
3. Try the sync again or manually cherry-pick your modifications
