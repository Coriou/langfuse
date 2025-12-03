# Keeping Your Fork in Sync

This document explains how to keep your `custom` branch in sync with the upstream Langfuse repository while preserving your Docker Compose modifications for Coolify.

## Overview

Your `custom` branch contains modifications to `docker-compose.yml` that make Langfuse work better with Coolify:
- Commented out localhost-bound ports (ClickHouse, Redis, PostgreSQL)
- Modified MinIO console port binding
- Simplified PostgreSQL environment variables

These changes are maintained on top of the latest upstream code using git rebase.

## Quick Sync (Automated)

The easiest way to sync with upstream is to use the provided script:

```bash
./sync-upstream.sh
```

This script will:
1. Check that you're on the `custom` branch
2. Stash any uncommitted changes
3. Fetch the latest changes from upstream
4. Show you what will change
5. Rebase your branch on top of upstream/main
6. Preserve your Docker Compose modifications
7. **Automatically update SHA-based image tags** to match the new version
8. Optionally restore your stashed changes

## Manual Sync Process

If you prefer to sync manually or need more control:

### 1. Fetch upstream changes

```bash
git fetch upstream
```

### 2. Check what's new

```bash
git log --oneline --graph HEAD..upstream/main
```

### 3. Rebase on upstream/main

```bash
git checkout custom
git rebase upstream/main
```

### 4. Resolve conflicts (if any)

If there are conflicts in `docker-compose.yml`, you'll need to manually reapply your Coolify changes:

```bash
# After rebase, check what changed
git diff v3.136.0 docker-compose.yml

# Manually reapply Coolify modifications:
# - MinIO: Change to docker.io/minio/minio:latest with curl healthcheck
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
- Uses `docker.io/minio/minio:latest` instead of `cgr.dev/chainguard/minio`
- Healthcheck uses `curl` instead of `mc ready local`
- Console port: `9091:9001` (not localhost-bound)

### Langfuse Images
- Uses SHA-based tags (e.g., `sha-895c516`) instead of version tags (`:3`)
- This pins deployments to specific builds for stability
- **The sync script automatically updates these SHAs** when syncing to a new version

### ClickHouse
- Ports 8123, 9000 commented out (services connect internally)

### Redis
- Port 6379 commented out (services connect internally)
- Removed `--maxmemory-policy noeviction` command flag

### PostgreSQL
- Simplified `POSTGRES_USER` to `postgres` (no env var fallback)
- Simplified `POSTGRES_DB` to `postgres` (no env var fallback)
- Removed `TZ` and `PGTZ` environment variables
- Port 5432 commented out (services connect internally)

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
git diff upstream/main docker-compose.yml
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
# 1. Sync upstream (automatically updates SHA tags)
./sync-upstream.sh

# 2. Test locally if possible
docker compose up -d

# 3. Push to your fork
git push origin custom --force-with-lease

# 4. Deploy to Coolify (triggers automatically if configured)
```

## Need Help?

If you encounter issues or the rebase becomes too complex:

1. Abort the current rebase: `git rebase --abort`
2. Create a backup of your changes: `git branch custom-backup`
3. Try the sync again or manually cherry-pick your modifications
