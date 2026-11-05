# Monica import request budget

`MONICA_RATE_LIMIT_PER_MINUTE` sets the number of outbound HTTP attempts Kith
admits per request host in a fixed one-minute window. It must be a positive
integer; invalid values stop startup. With no override, normal environments use
55, five below Monica's usual 60/min default. Tests have a separate high default.
Configure Kith below your server's actual `RATE_LIMIT_PER_MINUTE_API` and leave
headroom for other clients that use the same Monica quota. For example, use
`MONICA_RATE_LIMIT_PER_MINUTE=110` only when the server allows more than 110.

The shared boundary covers connection checks, contact crawls, misc endpoints,
photo listings and document downloads. Each initial request, retry and redirect
hop acquires one slot against its actual destination host. Different hosts have
independent budgets; accounts, API keys, URL schemes and ports on the same host
share one budget. A document redirected to another host consumes that host's
budget too. Requests block until admitted. Req handles finite retries and honors
`Retry-After`; photo sync has no separate fixed-delay retry loop. Limiter waits
and server retry delays can extend total request time beyond an attempt timeout.

The existing `RATE_LIMIT_BACKEND` controls counter scope. The default `ets`
backend limits each BEAM node independently. Multiple Kith nodes can therefore
send more than the configured budget in aggregate. With `redis`, nodes connected
to the same Redis backend share host counters. This setting does not coordinate
with other Monica clients or a different Redis deployment.

For a host development process, export the variable before `mix phx.server`;
Compose's `.env` file does not export variables into the host shell. The
supported `docker-compose.dev.yml` app and `docker-compose.prod.yml` app and
worker services forward the variable from the shell or Compose `.env`, defaulting
to 55. Production configures both services because web-side connection checks
also call Monica. Use the same value on nodes sharing a Redis budget.

Environment configuration is read at startup. Restart host processes after a
change. Recreate affected Compose containers (for example,
`docker compose -f docker-compose.prod.yml up -d --force-recreate app worker`);
a container restart alone retains its old environment. No image rebuild is
needed solely to change this option.
