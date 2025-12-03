# Coolify Deployment Guide

This guide explains how to deploy Langfuse to Coolify using the custom branch with Coolify-specific overrides.

## Overview

The `custom` branch maintains:
1. **Identical `docker-compose.yml`** to upstream (no modifications)
2. **`docker-compose.coolify.yml`** with Coolify-specific overrides
3. Your port binding preferences for Coolify's networking

## Quick Start

### Option 1: Configure Coolify to Use Override File (Recommended)

In your Coolify application settings:

1. **Docker Compose Location**: Set to use both files
   ```
   -f docker-compose.yml -f docker-compose.coolify.yml
   ```

2. **Branch**: `custom`

3. **Deploy**: Coolify will automatically use both files

### Option 2: Manual Docker Compose Command

If deploying manually or testing locally:

```bash
docker compose -f docker-compose.yml -f docker-compose.coolify.yml up -d
```

## What's Different in docker-compose.coolify.yml?

The override file changes only what's necessary for Coolify:

### MinIO Service
- **Image**: Uses `docker.io/minio/minio:latest` instead of `cgr.dev/chainguard/minio`
- **Reason**: Chainguard image's healthcheck fails in Coolify's environment
- **Healthcheck**: Uses `curl` instead of `mc ready local`
- **Impact**: More reliable startup and healthchecks

### Port Bindings
All your port customizations are in the base `docker-compose.yml`:
- ClickHouse ports commented out
- Redis ports commented out  
- PostgreSQL ports commented out
- MinIO console exposed on 9091 (not localhost-bound)

## How This Works

Docker Compose merges files from left to right:
1. Loads `docker-compose.yml` (base configuration)
2. Applies `docker-compose.coolify.yml` (overrides)
3. Final configuration uses Coolify-compatible settings

Services not mentioned in the override file use the base configuration unchanged.

## Keeping in Sync with Upstream

The `docker-compose.yml` stays **identical to upstream**, making syncing easy:

```bash
# Sync to latest stable tag (recommended)
./sync-upstream.sh

# Or sync to main branch
./sync-upstream.sh --main
```

After syncing:
- `docker-compose.yml` updates with latest upstream changes
- `docker-compose.coolify.yml` stays the same (your overrides)
- No merge conflicts on the compose file!

## Troubleshooting

### MinIO Still Unhealthy

If MinIO continues to fail healthchecks:

1. Check MinIO logs:
   ```bash
   docker logs minio-<container-id>
   ```

2. Increase healthcheck timing in `docker-compose.coolify.yml`:
   ```yaml
   minio:
     healthcheck:
       start_period: 30s
       interval: 10s
   ```

### Need More Overrides?

Add any Coolify-specific changes to `docker-compose.coolify.yml`:

```yaml
services:
  langfuse-web:
    environment:
      # Add Coolify-specific env vars
      CUSTOM_VAR: value
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

- **`main`**: Tracks upstream/main (not used for deployment)
- **`custom`**: Based on stable tags (e.g., v3.136.0) + your modifications
  - Deploy this branch to Coolify
  - Regularly sync with upstream stable releases

## Testing Locally

Before deploying to Coolify, test locally:

```bash
# Start services
docker compose -f docker-compose.yml -f docker-compose.coolify.yml up -d

# Check status
docker compose -f docker-compose.yml -f docker-compose.coolify.yml ps

# View logs
docker compose -f docker-compose.yml -f docker-compose.coolify.yml logs -f

# Stop services
docker compose -f docker-compose.yml -f docker-compose.coolify.yml down
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
