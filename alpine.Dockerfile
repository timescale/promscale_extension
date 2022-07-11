# syntax=docker/dockerfile:1.3-labs
ARG PG_VERSION=14
ARG TIMESCALEDB_VERSION_FULL=2.7.0
ARG PREVIOUS_IMAGE=timescaledev/promscale-extension:latest-ts2-pg${PG_VERSION}
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
    --mount=type=secret,uid=70,gid=70,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=70,gid=70,id=AWS_SECRET_ACCESS_KEY \
    [ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)" ; \
    [ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)" ; \
    sccache --show-stats && \
    cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev ee52db6b && \
    cargo pgx init --pg${PG_VERSION} $(which pg_config) && \
    sccache --show-stats

USER root
WORKDIR /build/promscale
RUN chown -R postgres:postgres /build
USER postgres

# Pre-build extension dependencies
RUN cd ../ && cargo pgx new promscale && cd promscale
COPY Cargo.* Makefile extract-extension-version.sh /build/promscale/
COPY test-common /build/promscale/test-common
COPY sql-tests /build/promscale/sql-tests
COPY e2e /build/promscale/e2e
COPY gendoc/ /build/promscale/gendoc/
RUN --mount=type=secret,uid=70,gid=70,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=70,gid=70,id=AWS_SECRET_ACCESS_KEY \
    --mount=type=cache,uid=70,gid=70,target=/build/promscale/.cargo/registry \
    [ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)" ; \
    [ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)" ; \
    sccache --show-stats && \
    make dependencies && \
    sccache --show-stats

# Build extension
COPY --chown=postgres:postgres Cargo.* /build/promscale/
COPY --chown=postgres:postgres Makefile build.rs create-upgrade-symlinks.sh extract-extension-version.sh /build/promscale/
COPY --chown=postgres:postgres .cargo/ /build/promscale/.cargo/
COPY --chown=postgres:postgres e2e/ /build/promscale/e2e/
COPY --chown=postgres:postgres src/ /build/promscale/src/
COPY --chown=postgres:postgres sql/*.sql /build/promscale/sql/
COPY --chown=postgres:postgres migration/ /build/promscale/migration
COPY --chown=postgres:postgres templates/ /build/promscale/templates/

RUN --mount=type=secret,uid=70,gid=70,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=70,gid=70,id=AWS_SECRET_ACCESS_KEY \
    --mount=type=cache,uid=70,gid=70,target=/build/promscale/.cargo/registry \
    [ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)" ; \
    [ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)" ; \
    sccache --show-stats && \
    make package && \
    sccache --show-stats

RUN env
RUN sccache --show-stats

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

FROM ${PREVIOUS_IMAGE} as prev_img

# COPY over the new files to the image. Done as a seperate stage so we don't
# ship the build tools.
FROM timescale/timescaledb:${TIMESCALEDB_VERSION_FULL}-pg${PG_VERSION}
ARG PG_VERSION

COPY --from=prev_img /usr/local/lib/postgresql/promscale*   /usr/local/lib/postgresql
COPY --from=prev_img /usr/local/share/postgresql/extension/promscale* /usr/local/share/postgresql/extension

COPY --from=builder /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/local/lib/postgresql /usr/local/lib/postgresql
COPY --from=builder /build/promscale/target/release/promscale-pg${PG_VERSION}/usr/local/share/postgresql /usr/local/share/postgresql
RUN mkdir -p /usr/local/lib/postgresql/plugins
COPY --from=pgextwlist-builder /pgextwlist/pgextwlist.so /usr/local/lib/postgresql/plugins
