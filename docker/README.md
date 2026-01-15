# Docker Setup

This folder contains Docker configuration files for the Poetry & Pottery workspace.

## Files

- `Dockerfile.api` - API server Docker image
- `Dockerfile.client` - Next.js client Docker image
- `docker-compose.local.yml` - Local development Docker Compose configuration

Each project has its own `.dockerignore` in its root folder.

## Usage

All commands should be run from the **workspace root directory**.

### Run All Services

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml --env-file poetry-and-pottery-infra/docker/.env up -d
```

### Run Services Individually

**Database only:**

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml --env-file poetry-and-pottery-infra/docker/.env up -d database
```

**API only** (requires database):

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml --env-file poetry-and-pottery-infra/docker/.env up -d api
```

**Client only** (requires API):

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml --env-file poetry-and-pottery-infra/docker/.env up -d client
```

### Force Rebuild

To force rebuild when files have changed:

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml --env-file poetry-and-pottery-infra/docker/.env up -d --build client
```

### Stop Services

**Stop all:**

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml down
```

**Stop specific service:**

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml stop client
```

### View Logs

```bash
docker compose -f poetry-and-pottery-infra/docker/docker-compose.local.yml logs -f client
```

## Building Individual Images

Build API image (from workspace root):

```bash
docker build -t poetry-and-pottery-api \
  --build-arg NODE_ENV=docker \
  --build-arg PORT=5050 \
  --build-arg DATABASE_URL=<your-database-url> \
  -f poetry-and-pottery-infra/docker/Dockerfile.api \
  poetry-and-pottery-api
```

Build client image (from workspace root):

```bash
docker build -t poetry-and-pottery-client \
  --build-arg NODE_ENV=docker \
  --build-arg DATABASE_URL=<your-database-url> \
  --build-arg API_ENDPOINT=<your-api-endpoint> \
  --build-arg NEXT_PUBLIC_DOMAIN=<your-domain> \
  --build-arg NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=<your-clerk-key> \
  -f poetry-and-pottery-infra/docker/Dockerfile.client \
  poetry-and-pottery
```
