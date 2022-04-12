ARG PG_VERSION=14
ARG TIMESCALEDB_VERSION_FULL=2.6.1
FROM timescale/timescaledb:${TIMESCALEDB_VERSION_FULL}-pg${PG_VERSION} as builder

MAINTAINER Timescale https://www.timescale.com
ARG RUST_VERSION=1.58.1
ARG PG_VERSION

RUN \
    apk add --no-cache --virtual .build-deps \
        curl \
        coreutils \
        gcc \
        libgcc \
        libc-dev \
        clang-libs \
        make \
        git \
        linux-headers \
        openssl-dev

WORKDIR /home/promscale

ENV HOME=/home/promscale \
    PATH=/home/promscale/.cargo/bin:$PATH

RUN chown postgres:postgres /home/promscale

# We must use a non-root user due to `pgx init` requirements
USER postgres

RUN \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --component rustfmt --default-toolchain $RUST_VERSION && \
    rustup --version && \
    rustc --version && \
    cargo --version

# Remove crt-static feature on musl target to allow building cdylibs
ENV RUSTFLAGS="-C target-feature=-crt-static"
RUN --mount=type=cache,uid=70,gid=70,target=/build/promscale/.cargo/registry \
    cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev ee52db6b && \
    cargo pgx init --pg${PG_VERSION} $(which pg_config)

USER root
WORKDIR /build/promscale
RUN chown -R postgres:postgres /build
USER postgres

# Pre-build extension dependencies
RUN cd ../ && cargo pgx new promscale && cd promscale
COPY Cargo.* Makefile /build/promscale/
COPY e2e /build/promscale/e2e
RUN --mount=type=cache,uid=70,gid=70,target=/build/promscale/.cargo/registry \
    make dependencies

# Build extension
COPY Cargo.* /build/promscale/
COPY promscale.control Makefile build.rs create-upgrade-symlinks.sh /build/promscale/
COPY .cargo/ /build/promscale/.cargo/
COPY e2e/ /build/promscale/e2e/
COPY src/ /build/promscale/src/
COPY sql/*.sql /build/promscale/sql/
COPY migration/ /build/promscale/migration
COPY templates/ /build/promscale/templates/

RUN --mount=type=cache,uid=70,gid=70,target=/build/promscale/.cargo/registry \
    make package

FROM timescale/timescaledb:${TIMESCALEDB_VERSION_FULL}-pg${PG_VERSION} as pgextwlist-builder

RUN \
    apk add --no-cache --virtual .build-deps \
        gcc \
        libc-dev \
        make \
        git \
        clang \
        llvm

RUN \
    git clone --branch v1.12 --depth 1 https://github.com/dimitri/pgextwlist.git /pgextwlist && \
    cd /pgextwlist && \
    make

# COPY over the new files to the image. Done as a seperate stage so we don't
# ship the build tools.
FROM timescale/timescaledb:${TIMESCALEDB_VERSION_FULL}-pg${PG_VERSION}
ARG PG_VERSION

COPY --from=builder /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/local/lib/postgresql /usr/local/lib/postgresql
COPY --from=builder /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/local/share/postgresql /usr/local/share/postgresql
RUN mkdir -p /usr/local/lib/postgresql/plugins
COPY --from=pgextwlist-builder /pgextwlist/pgextwlist.so /usr/local/lib/postgresql/plugins
