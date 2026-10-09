# PlaceOS Staff API

[![Build](https://github.com/PlaceOS/staff-api/actions/workflows/build.yml/badge.svg)](https://github.com/PlaceOS/staff-api/actions/workflows/build.yml)
[![CI](https://github.com/PlaceOS/staff-api/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/staff-api/actions/workflows/ci.yml)
[![Changelog](https://img.shields.io/badge/Changelog-available-github.svg)](/CHANGELOG.md)

Service for integrating [PlaceOS](https://placeos.com/) with the workplace.

## Environment

These environment variables are required for configuring an instance of Staff API

```console
SG_ENV=production

# Database config:
PG_DATABASE_URL=postgresql://user:password@hostname/placeos?max_pool_size=5&max_idle_pool_size=5

# Public key for decrypting and validating JWT tokens
JWT_PUBLIC=base64-public-key  #same one used by PlaceOS rest-api

# Redis, signals are published here for drivers and frontends to consume
REDIS_URL=redis://redis:6379
```

### Optional

```console
# Default Timezone
STAFF_TIME_ZONE=Australia/Sydney #default to UTC if not provided

# Sentry monitoring
SENTRY_DSN=<sentry dsn>

# Logstash log ingest
LOGSTASH_HOST=example.com
LOGSTASH_PORT=12345
```

## MCP Server

The API is also available to LLM clients (Claude Code, Claude Desktop, VS Code,
Cursor, ...) as an [MCP](https://modelcontextprotocol.io) server at
`/api/staff/v1/mcp`, using the Streamable HTTP transport.

```shell
claude mcp add --transport http placeos-staff https://<your-placeos-domain>/api/staff/v1/mcp
```

* **Signing in:** the client signs the user in through PlaceOS (OAuth with PKCE and
  a consent screen, served by auth). Tokens are refreshed automatically. Headless
  agents can send an API key instead, e.g. `--header "X-API-Key: <key>"`.
* **Tools:** each API resource (bookings, events, guests, calendars, ...) is a toolbox.
  The model opens the toolboxes it needs, which keeps its context small. Calls run as
  the signed in user, with their permissions.
* **Exposure:** the health check, user photos and the event change notifications used
  by drivers are not exposed (`@[AC::MCP(hide: true)]`).
* **Tool descriptions:** they come from the source code comments on the controllers
  and routes, so keep them accurate. The Docker build generates `mcp.yml` and ships
  it with the binary (`staff-api --mcp=mcp.yml`; override the location with
  `MCP_DESCRIPTION_PATH`). The model's instructions are in `src/mcp.cr`.

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).
