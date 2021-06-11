ARG PG_VERSION=12
ARG TIMESCALEDB_VERSION=1.7.5
FROM timescale/timescaledb-ha:pg${PG_VERSION}-ts${TIMESCALEDB_VERSION}-latest AS analytics-tools
ARG PG_VERSION

USER root

RUN mkdir rust

RUN set -ex \
    && apt-get update \
    && apt-get install -y \
        clang \
        gcc \
        git \
        libssl-dev \
        pkg-config \
        postgresql-server-dev-${PG_VERSION} \
        make

ENV CARGO_HOME=/build/.cargo
ENV RUSTUP_HOME=/build/.rustup
RUN curl https://sh.rustup.rs -sSf | bash -s -- -y --profile=minimal -c rustfmt
ENV PATH="/build/.cargo/bin:${PATH}"

#install pgx
RUN set -ex \
    && rm -rf "${CARGO_HOME}/registry" "${CARGO_HOME}/git" \
    && chown postgres:postgres -R "${CARGO_HOME}" \
    && cargo install --git https://github.com/JLockerman/pgx.git --branch timescale cargo-pgx \
    && cargo pgx init --pg${PG_VERSION} /usr/lib/postgresql/${PG_VERSION}/bin/pg_config

RUN set -ex \
    && git clone  --branch v1.11 --depth 1 \
         https://github.com/dimitri/pgextwlist.git /pgextwlist \
    && cd /pgextwlist \
    && make \
    && make install \
    && cp /pgextwlist/pgextwlist.so `pg_config --pkglibdir`/plugins \
    && rm -rf /pgextwlist

COPY promscale.control Makefile dependencies.makefile /rust/promscale/
COPY src/*.c src/*.h /rust/promscale/src/
COPY Cargo.* /rust/promscale/
COPY src/*.rs /rust/promscale/src/
COPY sql/*.sql /rust/promscale/sql/

RUN set -ex \
    && chown -R postgres:postgres /rust \
    && chown postgres:postgres -R "${CARGO_HOME}" \
    && chown postgres:postgres -R /usr/share/postgresql \
    && chown postgres:postgres -R /usr/lib/postgresql \
    && cd /rust/promscale \
        && cargo build --release --features pg${PG_VERSION} \
        && make -C /rust/promscale install

FROM timescale/timescaledb-ha:pg${PG_VERSION}-ts${TIMESCALEDB_VERSION}-latest as su-exec-builder

USER root
RUN  set -ex; \
     \
     curl -o /usr/local/bin/su-exec.c https://raw.githubusercontent.com/ncopa/su-exec/master/su-exec.c; \
     \
     fetch_deps='gcc libc-dev'; \
     apt-get update; \
     apt-get install -y --no-install-recommends $fetch_deps; \
     rm -rf /var/lib/apt/lists/*; \
     gcc -Wall \
         /usr/local/bin/su-exec.c -o/usr/local/bin/su-exec; \
     chown root:root /usr/local/bin/su-exec; \
     chmod 0755 /usr/local/bin/su-exec; \
     rm /usr/local/bin/su-exec.c; \
     \
     apt-get purge -y --auto-remove $fetch_deps


# COPY over the new files to the image. Done as a seperate stage so we don't
# ship the build tools.
FROM timescale/timescaledb-ha:pg${PG_VERSION}-ts${TIMESCALEDB_VERSION}-latest


USER root

ENV LANG=en_US.utf8 \
    LC_ALL=en_US.utf8

COPY --from=analytics-tools /usr/share/postgresql /usr/share/postgresql
COPY --from=analytics-tools /usr/lib/postgresql /usr/lib/postgresql
COPY --from=su-exec-builder /usr/local/bin/su-exec /usr/local/bin/su-exec
