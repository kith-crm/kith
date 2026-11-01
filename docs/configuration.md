# Kith Configuration & Integration Audit

## 1. Overview

Kith is configured exclusively through environment variables. No `.env` file is loaded in production — variables must be injected by the container orchestrator (Docker Compose, Kubernetes, etc.). In development, a `.env` file may be used via `mix dotenv` or a similar tool.

Variables are grouped by the implementation phase that introduces them. The "Phase" column corresponds to the sprint/phase number in the Kith product spec.

---

## 2. Environment Variables

### Core Application

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `DATABASE_URL` | string | — | 01 | Yes (prod) | PostgreSQL connection URL (e.g., `ecto://user:pass@host/db`) |
| `SECRET_KEY_BASE` | string | — | 01 | Yes (prod) | Phoenix secret key base; minimum 64 bytes. Generate with `mix phx.gen.secret`. |
| `KITH_HOSTNAME` | string | — | 01 | Yes (prod) | Public-facing hostname (e.g., `kith.example.com`). Used in generated URLs and email links. |
| `KITH_MODE` | enum(`web`/`worker`) | `web` | 01 | No | Container role. `web` starts the Phoenix HTTP endpoint. `worker` starts only the Oban job processor. Both use the same Docker image. |
| `PORT` | integer | `4000` | 01 | No | HTTP port the Phoenix endpoint listens on. |
| `POOL_SIZE` | integer | `10` | 01 | No | Ecto database connection pool size. Increase for high-concurrency deployments. |
| `PHX_HOST` | string | `localhost` | 01 | No | Phoenix endpoint host header. Overridden by `KITH_HOSTNAME` in production. |
| `DISABLE_SIGNUP` | boolean | `false` | 01 | No | When `true`, the registration endpoint returns 403. Existing users can still log in. |

### Authentication

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `SIGNUP_DOUBLE_OPTIN` | boolean | `true` | 02 | No | When `true`, new accounts must verify their email address before they can log in. Set to `false` for invite-only or trusted-network deployments. |

### File Storage

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `STORAGE_PATH` | string | `/app/uploads` | 13 | No | Absolute path for local disk storage. Used when `AWS_S3_BUCKET` is not set. Must be writable by the app process. |
| `AWS_S3_BUCKET` | string | — | 05 | No | S3 bucket name. Setting this variable switches the storage backend from local disk to S3. |
| `AWS_ACCESS_KEY_ID` | string | — | 05 | No | AWS access key ID. Required when `AWS_S3_BUCKET` is set. |
| `AWS_SECRET_ACCESS_KEY` | string | — | 05 | No | AWS secret access key. Required when `AWS_S3_BUCKET` is set. |
| `AWS_REGION` | string | `us-east-1` | 05 | No | AWS region for the S3 bucket. |
| `MAX_UPLOAD_SIZE_KB` | integer | `5120` | 05 | No | Maximum size for a single file upload, in kilobytes. Default is 5 MB. |
| `MAX_STORAGE_SIZE_MB` | integer | `1024` | 05 | No | Maximum total storage per user account, in megabytes. Default is 1 GB. |

### Integrations

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `IMMICH_BASE_URL` | string | — | 07 | No | Base URL of the Immich server (e.g., `https://photos.example.com`). Required to enable Immich integration. |
| `IMMICH_API_KEY` | string | — | 07 | No | Immich API key for read-only access. Required when `IMMICH_BASE_URL` is set. |
| `IMMICH_SYNC_INTERVAL_HOURS` | integer | `24` | 07 | No | Interval between Immich background sync runs, in hours. |
| `LOCATION_IQ_API_KEY` | string | — | 05 | No | LocationIQ API key for address geocoding. Required when `ENABLE_GEOLOCATION=true`. |
| `ENABLE_GEOLOCATION` | boolean | `false` | 05 | No | When `true`, enables forward geocoding of contact addresses via LocationIQ. |
| `GEOIP_DB_PATH` | string | — | 07 | No | Absolute path to a MaxMind-compatible GeoIP `.mmdb` database file. Used for IP-to-location lookups on login events. |

### Rate Limiting

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `RATE_LIMIT_BACKEND` | enum(`ets`/`redis`) | `ets` | 01 | No | Rate limiting storage backend. `ets` is in-process and suitable for single-node deployments. `redis` is required for multi-node deployments. |
| `REDIS_URL` | string | — | 01 | No | Redis connection URL (e.g., `redis://localhost:6379`). Required when `RATE_LIMIT_BACKEND=redis`. |
| `MONICA_RATE_LIMIT_PER_MINUTE` | integer | `55` | 07 | No | Requests per minute Kith sends to a Monica instance during API import, per Monica host. Raise it together with `RATE_LIMIT_PER_MINUTE_API` on a self-hosted Monica, keeping this value a call or two below Monica's. Must be a positive integer. |

### Networking

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `TRUSTED_PROXIES` | string | `127.0.0.1/8` | 01 | No | Comma-separated list of CIDR ranges for trusted reverse proxies. Used to correctly resolve client IP addresses from `X-Forwarded-For` headers. |

### Observability

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `SENTRY_DSN` | string | — | 07 | No | Sentry Data Source Name. When set, uncaught errors and Oban job failures are reported to Sentry. |
| `SENTRY_ENVIRONMENT` | string | `production` | 07 | No | Environment tag sent with Sentry events (e.g., `staging`, `production`). |
| `METRICS_TOKEN` | string | — | 12 | Yes (prod) | Bearer token required to access the `/metrics` Prometheus endpoint. Requests without a valid token receive 401. |

### Email

| Variable | Type | Default | Phase | Required | Description |
|---|---|---|---|---|---|
| `SMTP_HOST` | string | — | 01 | Yes (prod) | SMTP server hostname. |
| `SMTP_PORT` | integer | `587` | 01 | No | SMTP server port. Common values: `587` (STARTTLS), `465` (TLS), `25` (plain). |
| `SMTP_USERNAME` | string | — | 01 | No | SMTP authentication username. |
| `SMTP_PASSWORD` | string | — | 01 | No | SMTP authentication password. |
| `MAIL_FROM` | string | `noreply@kith.app` | 01 | No | Default "From" address for all outbound email. |

---

## 3. Rate Limit Backend Decision

### Default: ETS (in-memory, single-node)

By default, rate limiting uses Erlang ETS tables. This requires no external dependencies and is appropriate for all single-node deployments. ETS counters are local to the BEAM process and are reset on application restart.

### Switching to Redis

For multi-node deployments (multiple `web` containers behind a load balancer), rate limit state must be shared. Set:

```
RATE_LIMIT_BACKEND=redis
REDIS_URL=redis://redis:6379
```

### Startup Behavior

The application **must not crash** if Redis is unavailable at startup. The startup sequence is:

1. If `RATE_LIMIT_BACKEND=redis`, attempt to connect to Redis.
2. If connection fails, log a warning at the `warn` level:
   ```
   [warn] Redis unavailable at startup — falling back to ETS rate limiting
   ```
3. Continue startup using ETS as the backend.

This fallback ensures the application remains available during Redis maintenance windows. A health check or alert should be used to detect the degraded state.

### Summary

| Scenario | Backend | Notes |
|---|---|---|
| Single node | `ets` | Default, no configuration needed |
| Multi-node | `redis` | Set `RATE_LIMIT_BACKEND=redis` + `REDIS_URL` |
| Redis unavailable | `ets` (fallback) | Warn log emitted; app continues |

---

## 4. Storage Backend Decision

### Selection Logic

The storage backend is selected at runtime based on the presence of `AWS_S3_BUCKET`:

```
if AWS_S3_BUCKET is set
  → use S3 via ex_aws
else
  → use local disk at STORAGE_PATH
```

This check occurs in `Kith.Storage`, which is the single module all upload and retrieval calls route through. No other module references `ex_aws` directly.

### Local Disk

- Files are written to `STORAGE_PATH` (default `/app/uploads`).
- In Docker deployments, this path should be a named volume to survive container restarts.
- Not suitable for multi-node deployments (nodes would not share the same filesystem).

### S3 via ex_aws

- Kith uses `ex_aws` directly — there is **no Waffle dependency**.
- `Kith.Storage` implements a thin wrapper with two functions: `store/2` and `retrieve/1`.
- Pre-signed URLs are generated for direct browser downloads to avoid proxying large files through the app.
- Required variables when using S3: `AWS_S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.
- `AWS_REGION` defaults to `us-east-1` but should always be set explicitly.

### Quota Enforcement

Both backends enforce `MAX_UPLOAD_SIZE_KB` (per-file) and `MAX_STORAGE_SIZE_MB` (per-account). Quota is tracked in the database; `Kith.Storage` checks quota before accepting any upload and returns `{:error, :quota_exceeded}` if the limit would be exceeded.

---

## 5. .env.example Template

```dotenv
# =============================================================================
# Kith — Environment Variable Reference
# Copy this file to .env and fill in values for local development.
# In production, inject these as container environment variables directly.
# Do NOT commit a populated .env file to version control.
# =============================================================================

# -----------------------------------------------------------------------------
# Core Application
# -----------------------------------------------------------------------------

# PostgreSQL connection URL.
# Format: ecto://USER:PASS@HOST:PORT/DATABASE
DATABASE_URL=ecto://kith:kith@localhost:5432/kith_dev

# Phoenix secret key base. Generate with: mix phx.gen.secret
# Must be at least 64 bytes. Required in production.
SECRET_KEY_BASE=

# Public hostname (e.g., kith.example.com). Required in production.
KITH_HOSTNAME=localhost

# Container role: "web" (HTTP server) or "worker" (Oban jobs only).
KITH_MODE=web

# HTTP listen port.
PORT=4000

# Ecto connection pool size.
POOL_SIZE=10

# Phoenix endpoint host header.
PHX_HOST=localhost

# Set to true to disable new account registration.
DISABLE_SIGNUP=false

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------

# Set to false to skip email verification on signup (e.g., invite-only deploys).
SIGNUP_DOUBLE_OPTIN=true

# -----------------------------------------------------------------------------
# File Storage
# -----------------------------------------------------------------------------

# Local disk storage path (used when AWS_S3_BUCKET is not set).
STORAGE_PATH=/app/uploads

# S3 configuration — setting AWS_S3_BUCKET switches the backend to S3.
AWS_S3_BUCKET=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=us-east-1

# Per-file upload size limit (KB). Default 5 MB.
MAX_UPLOAD_SIZE_KB=5120

# Per-account total storage limit (MB). Default 1 GB.
MAX_STORAGE_SIZE_MB=1024

# -----------------------------------------------------------------------------
# Integrations
# -----------------------------------------------------------------------------

# Immich read-only integration. Set both to enable.
IMMICH_BASE_URL=
IMMICH_API_KEY=
IMMICH_SYNC_INTERVAL_HOURS=24

# LocationIQ geocoding. Set LOCATION_IQ_API_KEY and enable geolocation.
LOCATION_IQ_API_KEY=
ENABLE_GEOLOCATION=false

# Path to a MaxMind-compatible GeoIP .mmdb file for login IP lookups.
GEOIP_DB_PATH=

# -----------------------------------------------------------------------------
# Rate Limiting
# -----------------------------------------------------------------------------

# Backend: "ets" (default, single-node) or "redis" (multi-node).
RATE_LIMIT_BACKEND=ets

# Redis URL. Required when RATE_LIMIT_BACKEND=redis.
REDIS_URL=

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

# Comma-separated CIDRs for trusted reverse proxies.
TRUSTED_PROXIES=127.0.0.1/8

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------

# Sentry DSN for error tracking. Leave blank to disable.
SENTRY_DSN=
SENTRY_ENVIRONMENT=production

# Bearer token for the /metrics Prometheus endpoint. Required in production.
METRICS_TOKEN=

# -----------------------------------------------------------------------------
# Email (Swoosh / SMTP)
# -----------------------------------------------------------------------------

# SMTP server. Required in production.
SMTP_HOST=
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=

# Default "From" address for outbound email.
MAIL_FROM=noreply@kith.app
```
