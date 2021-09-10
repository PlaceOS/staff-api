ARG CRYSTAL_VERSION=1.1.1
FROM crystallang/crystal:${CRYSTAL_VERSION}-alpine as build
WORKDIR /app

# Set the commit through a build arg
ARG PLACE_COMMIT="DEV"

# Add trusted CAs for communicating with external services
RUN apk add --no-cache ca-certificates && update-ca-certificates

# Create a non-privileged user
# defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# See https://stackoverflow.com/a/55757473/12429735RUN
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

# Install shards for caching
COPY shard.yml .
COPY shard.override.yml .
COPY shard.lock .

RUN shards install --production --ignore-crystal-version

# Add src
COPY ./src src

# Build App
RUN PLACE_COMMIT=$PLACE_COMMIT \
    crystal build --release --error-trace src/staff-api.cr -o staff-api

# Extract dependencies
RUN ldd staff-api | tr -s '[:blank:]' '\n' | grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/
COPY --from=build /app/deps /
COPY --from=build /app/staff-api /app
COPY --from=build /etc/hosts /etc/hosts

# These provide certificate chain validation where communicating with external services over TLS
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# Copy the user information over
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# Use an unprivileged user.
USER appuser:appuser

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/app"]
HEALTHCHECK CMD ["/app", "-c", "http://127.0.0.1:8080/api/staff/v1"]
CMD ["/app", "-b", "0.0.0.0", "-p", "8080"]
