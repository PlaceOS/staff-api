# PlaceOS Staff API

[![Build](https://github.com/PlaceOS/staff-api/actions/workflows/build.yml/badge.svg)](https://github.com/PlaceOS/staff-api/actions/workflows/build.yml)
[![CI](https://github.com/PlaceOS/staff-api/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/staff-api/actions/workflows/ci.yml)
[![Changelog](https://img.shields.io/badge/Changelog-available-github.svg)](/CHANGELOG.md)

Service for integrating [PlaceOS](https://placeos.com/) with the workplace.

## Environment

These environment variables are required for configuring an instance of Staff API

```console
SG_ENV=production  # When set to production, the auth token in the request header will be used for auth, instead of static credentials from environment variables

# Database config:
PG_DATABASE_URL=postgresql://user:password@hostname/placeos?max_pool_size=5&max_idle_pool_size=5

# Public key for decrypting and validating JWT tokens
JWT_PUBLIC=base64-public-key  #same one used by PlaceOS rest-api

# Location of PlaceOS API
PLACE_URI=https://example.place.technology
```

### Optional

```console
# Default Timezone
STAFF_TIME_ZONE=Australia/Sydney #default to UTC if not provided

SSL_VERIFY_NONE=true # Whether staff-api should verify the SSL cert that PlaceOS rest-api presents

# Sentry monitoring
SENTRY_DSN=<sentry dsn>

# Logstash log ingest
LOGSTASH_HOST=example.com
LOGSTASH_PORT=12345

# Sentry monitoring
SENTRY_DSN=<sentry dsn>

# Logstash log ingest
LOGSTASH_HOST=example.com
LOGSTASH_PORT=12345
```

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).
