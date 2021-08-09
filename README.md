# PlaceOS Staff API

[![Build Dev Image](https://github.com/PlaceOS/staff-api/actions/workflows/build-dev-image.yml/badge.svg)](https://github.com/PlaceOS/staff-api/actions/workflows/build-dev-image.yml)
[![CI](https://github.com/PlaceOS/staff-api/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/staff-api/actions/workflows/ci.yml)

Service for integrating [PlaceOS](https://placeos.com/) with the workplace.

## Environment

These environment variables are required for configuring an instance of Staff API

```console
SG_ENV=production  # When set to production, the auth token in the request header will be used for auth, instead of static credentials from environment variables

# Database config:
PG_DATABASE_URL=postgresql://user:password@hostname/placeos

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

## Development

The `test` script spins up a configured development environment, and can be used like so...

```console
./test
```

or, to run specs as you make changes...

```console
./test --watch
```

**Note:** pass the `-Dquiet` flag to silence the SQL loging
