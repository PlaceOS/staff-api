ARG CRYSTAL_VERSION=latest

FROM placeos/crystal:$CRYSTAL_VERSION AS build
WORKDIR /app

# Set the commit through a build arg
ARG PLACE_COMMIT="DEV"
# Set the platform version via a build arg
ARG PLACE_VERSION="DEV"

# Create a non-privileged user, defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# See https://stackoverflow.com/a/55757473/12429735
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

RUN apk add \
  --update \
  --no-cache \
  libunwind-static \
  libunwind-dev \
  xz-static \
  xz-dev

# Install shards for caching
COPY shard.yml .
COPY shard.override.yml .
COPY shard.lock .

RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Add src
COPY ./src src

# Build App
RUN PLACE_COMMIT=$PLACE_COMMIT \
    shards build \
      --debug \
      --error-trace \
      --no-color \
      --static \
      -O1 \
      --frame-pointers=always \
      --link-flags "-no-pie -Wl,-no-pie -Wl,--eh-frame-hdr -Wl,--build-id -rdynamic -Wl,--export-dynamic -lunwind -llzma"

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN mkdir deps

# Extract binary dependencies
RUN for binary in /app/bin/*; do \
        file "$binary" | grep -q ELF || continue; \
        ldd "$binary" | \
        tr -s '[:blank:]' '\n' | \
        grep '^/' | \
        xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'; \
    done

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/

# Copy the user information over
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# These are required for communicating with external services
COPY --from=build /etc/hosts /etc/hosts

# These provide certificate chain validation where communicating with external services over TLS
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# Copy the app into place
COPY --from=build /app/deps /
COPY --from=build /app/bin /

# Use an unprivileged user.
USER appuser:appuser

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/staff-api"]
HEALTHCHECK CMD ["/staff-api", "-c", "http://127.0.0.1:8080/api/staff/v1"]
CMD ["/staff-api", "-b", "0.0.0.0", "-p", "8080"]
