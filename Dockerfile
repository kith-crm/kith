# Kith Production Dockerfile
# Multi-stage build: compile in builder, run in minimal alpine

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.5
ARG ALPINE_VERSION=3.23.5

# =============================================================================
# Stage 1: Builder
# =============================================================================
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION} AS builder

RUN apk add --no-cache git build-base nodejs npm

ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar (cached layer)
RUN mix local.hex --force && mix local.rebar --force

# Install dependencies (cached until mix.lock changes)
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy config (except runtime.exs which is read at container startup)
COPY config/config.exs config/prod.exs config/
# runtime.exs is needed at release build time for its structure,
# but values are read from env vars at container startup
COPY config/runtime.exs config/

# Compile assets (npm packages needed for Alpine.js CSP, Trix, tailwindcss-animate)
COPY assets assets
COPY priv priv
COPY lib lib
RUN mix assets.setup

# Compile application (must precede assets.deploy so phoenix_live_view
# compiler generates colocated hooks JS referenced by esbuild)
RUN mix compile
RUN mix assets.vendor
RUN mix assets.deploy

# Build release
RUN mix release

# =============================================================================
# Stage 2: Runner
# =============================================================================
FROM alpine:${ALPINE_VERSION} AS runner

RUN apk add --no-cache \
    libssl3 \
    libcrypto3 \
    libstdc++ \
    libgcc \
    ncurses-libs \
    ca-certificates \
    curl \
    && rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 kith && adduser -u 1000 -G kith -D kith

WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=kith:kith /app/_build/prod/rel/kith ./

# Create uploads directory for local file storage
RUN mkdir -p /app/uploads && chown kith:kith /app/uploads

# Switch to non-root user
USER kith

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:4000/health/live || exit 1

ENTRYPOINT ["/app/bin/kith"]
CMD ["start"]
