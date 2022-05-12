# This dockerfile is a helper for quick iteration on the extension SQL
# To use, first run: `make docker-image-14`, then edit SQL and run `make docker-quick-14`
ARG PG_VERSION
ARG TIMESCALEDB_VERSION_MAJOR
ARG EXTENSION_VERSION
FROM local/dev_promscale_extension:head-ts${TIMESCALEDB_VERSION_MAJOR}-pg${PG_VERSION}

ARG EXTENSION_VERSION
COPY sql/promscale-${EXTENSION_VERSION}.sql /usr/local/share/postgresql/extension/promscale--${EXTENSION_VERSION}.sql
# TODO (james): This probably needs to be extended to be created for all `upgradeable_from` in promscale.control
COPY sql/promscale-${EXTENSION_VERSION}.sql /usr/local/share/postgresql/extension/promscale--0.0.0--${EXTENSION_VERSION}.sql
# TODO (john): for now, we need the "takeover" script copied too since it's still not final
 COPY sql/promscale--0.0.0.sql /usr/local/share/postgresql/extension/promscale--0.0.0.sql
