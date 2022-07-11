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

RUN <<EOF
    curl -L "https://github.com/mozilla/sccache/releases/download/v0.2.15/sccache-v0.2.15-x86_64-unknown-linux-musl.tar.gz" | tar zxf -
    chmod +x sccache-*/sccache
    mv sccache-*/sccache /usr/local/bin/sccache
    sccache --show-stats
EOF

ENV RUSTC_WRAPPER=sccache
ENV SCCACHE_BUCKET=promscale-extension-sccache

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

RUN --mount=type=secret,uid=1000,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=1000,id=AWS_SECRET_ACCESS_KEY \
    [ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)" ; \
    [ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)" ; \
    sccache --show-stats && \
    cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev ee52db6b && \
    sccache --show-stats

RUN cargo pgx init --pg${PG_VERSION} /usr/lib/postgresql/${PG_VERSION}/bin/pg_config

WORKDIR /build/promscale
RUN chown -R postgres:postgres /build

USER postgres

COPY --chown=postgres:postgres Cargo.* /build/promscale/
COPY --chown=postgres:postgres Makefile build.rs create-upgrade-symlinks.sh extract-extension-version.sh /build/promscale/
COPY --chown=postgres:postgres .cargo/ /build/promscale/.cargo/
COPY --chown=postgres:postgres test-common/ /build/promscale/test-common/
COPY --chown=postgres:postgres sql-tests/ /build/promscale/sql-tests/
COPY --chown=postgres:postgres e2e/ /build/promscale/e2e/
COPY --chown=postgres:postgres src/ /build/promscale/src/
COPY --chown=postgres:postgres gendoc/ /build/promscale/gendoc/
COPY --chown=postgres:postgres sql/*.sql /build/promscale/sql/
COPY --chown=postgres:postgres migration/ /build/promscale/migration
COPY --chown=postgres:postgres templates/ /build/promscale/templates/

RUN --mount=type=secret,uid=1000,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=1000,id=AWS_SECRET_ACCESS_KEY \
    [ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)" ; \
    [ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)" ; \
    sccache --show-stats && \
    make package && \
    sccache --show-stats

# Yes, fixed pg14 image is intentional. The image ships with PG 12, 13 and 14 binaries
# PATH environment variable below is used to specify runtime version.
FROM timescale/timescaledb-ha:pg14-ts${TIMESCALEDB_VERSION_MAJMIN}-latest
ARG PG_VERSION
COPY --from=builder --chown=root:postgres /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/lib/postgresql /usr/lib/postgresql
COPY --from=builder --chown=root:postgres /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/share/postgresql /usr/share/postgresql
ENV PATH="/usr/lib/postgresql/${PG_VERSION}/bin:${PATH}"
USER root
# The timescale/timescaledb-ha docker image sets the sticky bit on the lib and extension directories, which we overwrote
# with the copy above. We need to set it back and set permissions correctly to allow us to later (in a test) remove the
# timescale extension files (for our "no timescaledb" tests).
RUN chmod 1775 /usr/lib/postgresql/${PG_VERSION}/lib
RUN chmod 1775 /usr/share/postgresql/${PG_VERSION}/extension
USER postgres
