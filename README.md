[![Build Status](https://travis-ci.com/red-ant/staff-api.svg?token=RzVfSpK1WxvVvMdpTs99&branch=master)](https://travis-ci.com/red-ant/staff-api)
[![CI](https://github.com/place-labs/staff-api/actions/workflows/ci.yml/badge.svg)](https://github.com/place-labs/staff-api/actions/workflows/ci.yml)

# PlaceOS Staff API

## Environment Variables required for Production/Staging and local development use, e.g. [partner-environment](https://github.com/place-labs/partner-environment/)

```
SG_ENV=production  # When set to production, the auth token in the request header will be used for auth, instead of static credentials from environment variables

# Database config:
PG_DATABASE_URL=postgresql://user:password@hostname/placeos

# Public key for decrypting and validating JWT tokens
JWT_PUBLIC=base64-public-key  #same one used by PlaceOS rest-api

# Location of PlaceOS API
PLACE_URI=https://example.place.technology
```
## Optional environment variables
``
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
``

## Local development

```
brew install postgres

# Setup the data store
sudo su
mkdir -p /usr/local/pgsql
chown steve /usr/local/pgsql
exit

initdb /usr/local/pgsql/data

# Then can start the service in the background
pg_ctl -D /usr/local/pgsql/data start

# Or start it in the foreground
postgres -D /usr/local/pgsql/data

# This seems to be required
createdb

# Now the server is running with default user the same as your Mac login
psql -c 'create database travis_test;'
export PG_DATABASE_URL=postgresql://localhost/travis_test
```

Alternatively with Docker:

```
./test
```

## Testing

Use the `-Dquiet` flag to silence the SQL loging
