# Deployment Guide

## Quick Start (Fresh Install)

```bash
# 1. Clone the repository
git clone https://github.com/your-org/kith.git
cd kith

# 2. Create environment file
cp .env.example .env
chmod 600 .env

# 3. Generate secrets and fill in .env
#    SECRET_KEY_BASE:
mix phx.gen.secret
#    AUTH_TOKEN_SALT:
mix phx.gen.secret
#    CLOAK_KEY (32-byte base64):
openssl rand -base64 32
#    METRICS_TOKEN:
openssl rand -base64 32

# 4. Set your hostname in .env
#    KITH_HOSTNAME=kith.example.com  (for production with TLS)
#    KITH_HOSTNAME=localhost          (for local testing)

# 5. Set database credentials in .env
#    POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
#    DATABASE_URL=ecto://USER:PASSWORD@postgres:5432/DB

# 6. Build the Docker image
docker build -t kith:latest .

# 7. Start all services
docker compose -f docker-compose.prod.yml up -d

# 8. Verify deployment
curl http://localhost/health/ready
# Expected: {"status":"ok","db":"connected","migrations":"current"}
```

## Upgrade

```bash
# 1. Pull latest code
git pull

# 2. Rebuild the Docker image
docker build -t kith:latest .

# 3. Run database migrations
docker compose -f docker-compose.prod.yml run --rm migrate

# 4. Restart app and worker with new image
docker compose -f docker-compose.prod.yml up -d app worker

# 5. Verify
curl https://kith.example.com/health/ready
```

## Environment Variables

All configuration is via environment variables in `.env`. See `.env.example` for the complete list with documentation.

**Required variables (no defaults):**

| Variable | Description |
|----------|-------------|
| `SECRET_KEY_BASE` | Phoenix session signing key (64+ chars) |
| `DATABASE_URL` | PostgreSQL connection string |
| `AUTH_TOKEN_SALT` | Token signing salt |
| `CLOAK_KEY` | Field encryption key (32-byte base64) |
| `POSTGRES_PASSWORD` | PostgreSQL container password |
| `METRICS_TOKEN` | Bearer token for `/metrics` endpoint |

**Important optional variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `KITH_HOSTNAME` | `localhost` | Domain name (enables TLS when not localhost) |
| `KITH_MODE` | `web` | `web` for HTTP server, `worker` for Oban only |
| `MAILER_ADAPTER` | `smtp` | Email provider: smtp, mailgun, ses, postmark |
| `AWS_S3_BUCKET` | (empty) | Set to enable S3 storage instead of local disk |
| `SENTRY_DSN` | (empty) | Set to enable Sentry error tracking |

## Architecture

```
Internet → Caddy (TLS, headers) → App (Phoenix, port 4000)
                                     ↕
                                  PostgreSQL
                                     ↕
                                  Worker (Oban jobs)
```

- **Caddy** handles TLS termination, security headers, static asset caching, and WebSocket passthrough for LiveView
- **App** serves HTTP, LiveView WebSocket connections, and the REST API
- **Worker** processes background jobs (email, imports, reminders) via Oban
- **Migrate** runs database migrations once on startup, then exits
- Only Caddy exposes ports to the host (80, 443)

## Service Management

```bash
# View service status
docker compose -f docker-compose.prod.yml ps

# View logs
docker compose -f docker-compose.prod.yml logs app
docker compose -f docker-compose.prod.yml logs worker
docker compose -f docker-compose.prod.yml logs caddy

# Follow logs in real time
docker compose -f docker-compose.prod.yml logs -f app worker

# Restart a specific service
docker compose -f docker-compose.prod.yml restart app

# Stop all services
docker compose -f docker-compose.prod.yml down

# Stop and remove volumes (DESTRUCTIVE — deletes all data)
# docker compose -f docker-compose.prod.yml down -v
```

## Health Checks

| Endpoint | Purpose | Auth Required |
|----------|---------|---------------|
| `GET /health/live` | Liveness probe — BEAM process is alive | No |
| `GET /health/ready` | Readiness probe — DB connected, migrations current | No |
| `GET /metrics` | Prometheus metrics | Bearer token (`METRICS_TOKEN`) |

## Troubleshooting

**Container won't start:**
```bash
docker compose -f docker-compose.prod.yml logs app
# Look for: missing env vars, database connection errors, port conflicts
```

**Migration fails:**
```bash
docker compose -f docker-compose.prod.yml logs migrate
# Common causes: DATABASE_URL wrong, postgres not ready, migration conflict
```

**LiveView WebSocket disconnects:**
- Verify `KITH_HOSTNAME` matches the actual hostname in the browser URL
- Check Caddy logs for WebSocket upgrade errors
- Ensure no intermediate proxy strips WebSocket headers

**Email not sending:**
```bash
docker compose -f docker-compose.prod.yml logs worker
# Check SMTP credentials, MAILER_ADAPTER setting, firewall rules for SMTP port
```

**Health check failing:**
```bash
# Check if app is running
docker compose -f docker-compose.prod.yml ps app

# Check database connectivity
docker compose -f docker-compose.prod.yml exec postgres pg_isready

# Hit health endpoint directly
docker compose -f docker-compose.prod.yml exec app curl -s http://localhost:4000/health/ready
```

**High memory usage:**
- Check current limits: `docker stats`
- Adjust resource limits in `docker-compose.prod.yml`
- BEAM processes can use significant memory for large mailboxes; monitor and adjust

## Security

- Container runs as non-root user (UID 1000)
- All capabilities dropped (`cap_drop: ALL`)
- Privilege escalation prevented (`no-new-privileges`)
- Read-only root filesystem with tmpfs for `/tmp`
- PostgreSQL is internal-only (no exposed ports)
- `.env` file should have `chmod 600` permissions
- See `.dockerignore` for build context exclusions

## Further Reading

- [Volume Management](volumes.md) — backup and restore procedures
- [Scaling Notes](scaling.md) — how to scale beyond a single node


## Authentication upgrades

Follow [OIDC registration, TLS, proxy privacy and operator recovery](oidc.md)
before enabling external login or disabling passwords. Back up and test restore
before migration; passwordless users prevent a naive NOT NULL downgrade.
[DAV app passwords](dav-app-passwords.md) cover personal client setup and revocation.
The [acceptance map](../design/oidc-validation/acceptance.md) records validation and
explicit Android/DAVx5/live-provider gaps; phone viewport tests are not device proof.
