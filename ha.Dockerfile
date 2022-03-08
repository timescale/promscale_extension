# syntax=docker/dockerfile:1.3-labs
ARG PG_VERSION=14
ARG TIMESCALEDB_VERSION_MAJMIN=2.6
FROM ubuntu:21.10 as builder
ARG PG_VERSION

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt-get install -y clang pkg-config wget lsb-release libssl-dev curl gnupg2 binutils devscripts equivs git libkrb5-dev libperl-dev make

RUN wget -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --output /usr/share/keyrings/postgresql.keyring
RUN for t in deb deb-src; do \
        echo "$t [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/postgresql.keyring] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -s -c)-pgdg main" >> /etc/apt/sources.list.d/pgdg.list; \
    done

RUN apt-get update

RUN apt-get install -y postgresql-${PG_VERSION} postgresql-server-dev-${PG_VERSION}

WORKDIR /home/promscale

ENV HOME=/home/promscale \
    PATH=/home/promscale/.cargo/bin:$PATH

RUN chown postgres:postgres /home/promscale

USER postgres

ENV RUST_VERSION=1.58.1

RUN \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --component rustfmt --default-toolchain ${RUST_VERSION} && \
    rustup --version && \
    rustc --version && \
    cargo --version

RUN cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev ee52db6b

RUN cargo pgx init --pg${PG_VERSION} /usr/lib/postgresql/${PG_VERSION}/bin/pg_config

WORKDIR /build/promscale
RUN chown -R postgres:postgres /build

USER postgres

COPY --chown=postgres:postgres Cargo.* /build/promscale/
COPY --chown=postgres:postgres promscale.control Makefile build.rs create-upgrade-symlinks.sh /build/promscale/
COPY --chown=postgres:postgres .cargo/ /build/promscale/.cargo/
COPY --chown=postgres:postgres e2e/ /build/promscale/e2e/
COPY --chown=postgres:postgres src/ /build/promscale/src/
COPY --chown=postgres:postgres sql/*.sql /build/promscale/sql/
COPY --chown=postgres:postgres migration/ /build/promscale/migration
COPY --chown=postgres:postgres templates/ /build/promscale/templates/

RUN make package

FROM timescale/timescaledb-ha:pg${PG_VERSION}-ts${TIMESCALEDB_VERSION_MAJMIN}-latest
ARG PG_VERSION
COPY --from=builder --chown=root:postgres /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/lib/postgresql /usr/lib/postgresql
COPY --from=builder --chown=root:postgres /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/share/postgresql /usr/share/postgresql
USER root
# The timescale/timescaledb-ha docker image sets the sticky bit on the lib and extension directories, which we overwrote
# with the copy above. We need to set it back and set permissions correctly to allow us to later (in a test) remove the
# timescale extension files (for our "no timescaledb" tests).
RUN chmod 1775 /usr/lib/postgresql/${PG_VERSION}/lib
RUN chmod 1775 /usr/share/postgresql/${PG_VERSION}/extension
USER postgres
