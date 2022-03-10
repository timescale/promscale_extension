# This dockerfile is a helper for quick iteration on the extension SQL
# To use, first run: `make docker-image-14`, then edit SQL and run `make docker-quick-14`
ARG PG_VERSION_TAG
ARG TIMESCALEDB_VERSION
ARG EXTENSION_VERSION
FROM timescaledev/promscale-extension:${EXTENSION_VERSION}-${TIMESCALEDB_VERSION}-${PG_VERSION_TAG}

ARG EXTENSION_VERSION
COPY sql/promscale-${EXTENSION_VERSION}.sql /usr/local/share/postgresql/extension/promscale--${EXTENSION_VERSION}.sql
# TODO (james): This probably needs to be extended to be created for all `upgradeable_from` in promscale.control
COPY sql/promscale-${EXTENSION_VERSION}.sql /usr/local/share/postgresql/extension/promscale--0.0.0--${EXTENSION_VERSION}.sql

