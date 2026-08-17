# Coolify Deployment Guide

This guide explains how to deploy Langfuse to Coolify using the custom branch.

## Overview

The `custom` branch is optimized for Coolify with these modifications:

1. **MinIO**: Uses `docker.io/minio/minio` with curl-based healthcheck (fixes Chainguard image issues)
2. **Ports**: All internal service ports commented out (Coolify routes via Docker network)
3. **Web/worker**: Bound to `127.0.0.1` so only Coolify's Traefik can reach them
4. **PostgreSQL**: Simplified env vars, tuned for small instances (128MB shared_buffers)
5. **Redis**: `maxmemory 192mb` + persistent volume for BullMQ queue durability across redeploys
6. **ClickHouse**: Memory cap + system-log TTL + log-rotation overrides mounted from `./clickhouse-config-d/`
7. **Resource limits**: Memory caps on every service so one spike can't OOM the host
8. **Healthcheck**: Explicit `/api/public/health` probe on langfuse-web for Coolify status

Based on stable upstream tag **v3.225.2** for reliability.

> **Why not v3.225.3?** It is the newer v3 git tag, but upstream never published a
> container image for it — neither `langfuse/langfuse:sha-f6c77b7` nor `:3.225.3`
> exists on Docker Hub or ghcr.io. Since we deploy prebuilt images, there is nothing
> to pull. Revisit if upstream backfills that build.

## Quick Start

In your Coolify application settings:

1. **Docker Compose Location**: `docker-compose.yml` (default)
2. **Branch**: `custom`
3. **Deploy**: Click deploy

That's it! All changes are in the single `docker-compose.yml` file.

## Modifications from Upstream

The `custom` branch contains these Coolify-specific changes:

### MinIO Service
```yaml
image: docker.io/minio/minio:RELEASE.2025-07-23T15-54-02Z  # Instead of cgr.dev/chainguard/minio
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
ports:
  - 9090:9000
  - 9091:9001  # Not localhost-bound for Coolify access
```

### Internal Services (ClickHouse, Redis, PostgreSQL)
All internal service ports are commented out - they communicate via Docker network names:
```yaml
# ports:
  # - 127.0.0.1:6379:6379
```

## Keeping in Sync with Upstream

> **Do not run `./sync-upstream.sh` unattended.** It picks the highest stable tag
> (`sort -V | tail -1`), which now resolves to **v4.x**. We are deliberately on the v3
> line, so the script would rebase us straight onto a major version. Pass an explicit
> v3 tag or rebase by hand until the script learns a version constraint.

To sync manually to a chosen v3 tag:

```bash
git fetch upstream --tags
git rebase v3.225.2          # or whichever v3 tag you intend
```

Then update the two Langfuse image tags in `docker-compose.yml` to the `sha-<7char>`
of that tag's commit — and **verify the image actually exists** before committing:

```bash
docker manifest inspect docker.io/langfuse/langfuse:sha-<7char>
```

Not every upstream git tag gets a published image (v3.225.3 did not).

**Note**: After syncing, check that the Coolify changes survived (MinIO image, port
comments, etc.) in case upstream modified those sections.

## Troubleshooting

### Port Already Allocated Error

If you see "port is already allocated" errors, ensure all localhost-bound ports are commented out in `docker-compose.yml`:
- ClickHouse: 8123, 9000
- Redis: 6379
- PostgreSQL: 5432

### MinIO Unhealthy

If MinIO fails healthchecks, check the logs in Coolify or increase the `start_period`:
```yaml
minio:
  healthcheck:
    start_period: 30s  # Give MinIO more time to start
```

## Environment Variables

All environment variables work the same way. Set them in Coolify's environment configuration or use a `.env` file.

Key variables for Coolify:
```bash
NEXTAUTH_URL=https://your-langfuse-domain.com
DATABASE_URL=postgresql://postgres:postgres@postgres:5432/postgres
SALT=<your-random-salt>
ENCRYPTION_KEY=<64-char-hex-key>
NEXTAUTH_SECRET=<random-secret>

# MinIO credentials
MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=<secure-password>

# Redis password
REDIS_AUTH=<redis-password>

# ClickHouse password
CLICKHOUSE_PASSWORD=<clickhouse-password>

# PostgreSQL password
POSTGRES_PASSWORD=<postgres-password>
```

## Branch Strategy

- **`main`**: Tracks upstream/main (for reference only)
- **`custom`**: Based on stable v3 tags (currently v3.225.2) with Coolify modifications
  - **Deploy this branch to Coolify**
  - Sync regularly with `./sync-upstream.sh` to get new releases

## Summary of Changes

Your `custom` branch differs from upstream in these ways:

**Coolify compatibility**
1. MinIO uses standard `docker.io/minio/minio` image with `curl` healthcheck
2. MinIO console port not localhost-bound (`9091:9001`)
3. ClickHouse, Redis, PostgreSQL ports commented out (Docker-network only)
4. PostgreSQL `TZ` / `PGTZ` env vars removed (Coolify provides defaults)
5. langfuse-web bound to `127.0.0.1:3000` (Coolify Traefik proxies to localhost)

**Self-hosting tuning**
6. `deploy.resources.limits` on every service (caps total Langfuse footprint to ~4GB)
7. ClickHouse memory cap + log-rotation + system-log TTL via `./clickhouse-config-d/`
8. Redis `maxmemory 192mb` and persistent volume for BullMQ
9. Postgres `shared_buffers=128MB` for small-RAM hosts
10. langfuse-web healthcheck via `/api/public/health` for Coolify status
11. All four images pinned to exact versions (see "Image pinning" below)

### ClickHouse config overrides

Everything in `./clickhouse-config-d/` is mounted read-only at
`/etc/clickhouse-server/config.d`:

| File | Purpose |
|---|---|
| `memory_limits.xml` | Caps the server memory budget so it fits the 1.5 GiB cgroup |
| `listen_host.xml` | Binds `0.0.0.0` so other containers can connect |
| `server_logging.xml` | Log level + rotation |
| `system_logs_ttl.xml` | TTL on `system.*` tables so they don't grow unbounded |

`memory_limits.xml` is load-bearing. ClickHouse sizes its default memory budget from
**host** RAM, not from the container's cgroup limit — on an 8 GB host it plans for
~6.8 GiB inside a 1.5 GiB cgroup and is OOM-killed on every start. Without this file
the container crash-loops indefinitely (it once did so 94,000+ times over two months).

**Coolify re-materialises this directory from git on every deploy.** A fix applied by
hand on the host will be silently reverted the next time you deploy. Edit these files
here, in the repo, never on the server.

### Image pinning

| Service | Pinned to |
|---|---|
| langfuse-web / langfuse-worker | `sha-8ff44b6` (v3.225.2) |
| clickhouse-server | `25.7.3.13` |
| minio | `RELEASE.2025-07-23T15-54-02Z` |

ClickHouse and MinIO previously floated on `:latest`, which meant a redeploy could pull
a new major version with no commit to point at. Both are now explicit. `redis:7` and
`postgres:17` still float within a major version, matching upstream's default.

**The host is ARM.** `apps.coriou.net` is aarch64 (Hetzner ARM), so an amd64-only image
is a hard blocker — it will not run at all. All four pinned images publish both
`linux/amd64` and `linux/arm64`. Verify the platform list before any bump:

```bash
docker manifest inspect docker.io/<image>:<tag> \
  | jq -r '.manifests[].platform | .os + "/" + .architecture'
```

These changes ensure smooth deployment in Coolify's containerized environment
on small (≤8GB RAM) hosts.

## Testing Locally

Before deploying to Coolify, test locally:

```bash
# Start services
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f

# Stop services
docker compose down
```

## Production Checklist

Before deploying to production:

- [ ] Update all `# CHANGEME` passwords in environment variables
- [ ] Set `NEXTAUTH_URL` to your production domain
- [ ] Generate secure `ENCRYPTION_KEY` with `openssl rand -hex 32`
- [ ] Generate secure `NEXTAUTH_SECRET`
- [ ] Configure SMTP for emails (optional)
- [ ] Set up backups for volumes (postgres, clickhouse, minio data)
- [ ] Test deployment in staging environment first

## Support

- **Langfuse Issues**: Report to [langfuse/langfuse](https://github.com/langfuse/langfuse)
- **Coolify Issues**: Report to [coollabsio/coolify](https://github.com/coollabsio/coolify)
- **This Setup**: Issues specific to this fork configuration
