# Coolify Deployment Guide

This guide explains how to deploy Langfuse to Coolify using the custom branch.

## Overview

The `custom` branch is optimized for Coolify with these modifications:

1. **MinIO**: Uses `docker.io/minio/minio:latest` with curl-based healthcheck (fixes Chainguard image issues)
2. **Ports**: All internal service ports commented out (Coolify routes via Docker network)
3. **Web/worker**: Bound to `127.0.0.1` so only Coolify's Traefik can reach them
4. **PostgreSQL**: Simplified env vars, tuned for small instances (128MB shared_buffers)
5. **Redis**: `maxmemory 192mb` + persistent volume for BullMQ queue durability across redeploys
6. **ClickHouse**: System-log TTL + log-rotation overrides mounted from `./clickhouse-config-d/`
7. **Resource limits**: Memory caps on every service so one spike can't OOM the host
8. **Healthcheck**: Explicit `/api/public/health` probe on langfuse-web for Coolify status

Based on stable upstream tag **v3.174.1** for reliability.

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
image: docker.io/minio/minio:latest  # Instead of cgr.dev/chainguard/minio
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

Sync to the latest stable release:

```bash
./sync-upstream.sh
```

This will:
1. Fetch the latest stable tag from upstream
2. Rebase your custom branch on top of it
3. Preserve your Coolify-specific modifications

**Note**: After syncing, you'll need to manually reapply the Coolify changes (MinIO image, port comments, etc.) if upstream modified those sections.

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
- **`custom`**: Based on stable tags (e.g., v3.136.0) with Coolify modifications
  - **Deploy this branch to Coolify**
  - Sync regularly with `./sync-upstream.sh` to get new releases

## Summary of Changes

Your `custom` branch differs from upstream in these ways:

**Coolify compatibility**
1. MinIO uses standard `docker.io/minio/minio:latest` image with `curl` healthcheck
2. MinIO console port not localhost-bound (`9091:9001`)
3. ClickHouse, Redis, PostgreSQL ports commented out (Docker-network only)
4. PostgreSQL `TZ` / `PGTZ` env vars removed (Coolify provides defaults)
5. langfuse-web bound to `127.0.0.1:3000` (Coolify Traefik proxies to localhost)

**Self-hosting tuning**
6. `deploy.resources.limits` on every service (caps total Langfuse footprint to ~4GB)
7. ClickHouse log-rotation + system-log TTL via `./clickhouse-config-d/`
8. Redis `maxmemory 192mb` and persistent volume for BullMQ
9. Postgres `shared_buffers=128MB` for small-RAM hosts
10. langfuse-web healthcheck via `/api/public/health` for Coolify status

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
