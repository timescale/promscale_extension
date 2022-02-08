ARG PG_VERSION_TAG=pg12
ARG TIMESCALEDB_VERSION=1.7.5
FROM timescale/timescaledb:${TIMESCALEDB_VERSION}-${PG_VERSION_TAG} as builder

MAINTAINER Timescale https://www.timescale.com
ARG RUST_VERSION=1.57.0
ARG PG_VERSION_TAG

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
    cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev 271be6a1 && \
    cargo pgx init --${PG_VERSION_TAG} $(which pg_config)

USER root
WORKDIR /build/promscale
RUN chown postgres:postgres /build/promscale
USER postgres

# Build extension
COPY Cargo.* /build/promscale/
COPY promscale.control Makefile /build/promscale/
COPY .cargo/ /build/promscale/.cargo/
COPY src/ /build/promscale/src/
COPY sql/*.sql /build/promscale/sql/

RUN --mount=type=cache,uid=70,gid=70,target=/build/promscale/.cargo/registry \
    make package

# COPY over the new files to the image. Done as a seperate stage so we don't
# ship the build tools.
FROM timescale/timescaledb:${TIMESCALEDB_VERSION}-${PG_VERSION_TAG}
ARG PG_VERSION_TAG

COPY --from=builder /build/promscale/target/release/promscale-${PG_VERSION_TAG}/usr/local/lib/postgresql /usr/local/lib/postgresql
COPY --from=builder /build/promscale/target/release/promscale-${PG_VERSION_TAG}/usr/local/share/postgresql /usr/local/share/postgresql
