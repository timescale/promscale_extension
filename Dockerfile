ARG PG_VERSION_TAG=pg12
ARG TIMESCALEDB_VERSION=1.7.5
FROM timescale/timescaledb:${TIMESCALEDB_VERSION}-${PG_VERSION_TAG} as builder

MAINTAINER Timescale https://www.timescale.com
ARG PG_VERSION_TAG

RUN set -ex \
    && apk add --no-cache --virtual .build-deps \
                coreutils \
                dpkg-dev dpkg \
                gcc \
                libc-dev \
                make \
                util-linux-dev \
                clang \
		llvm \
                git \
                llvm-dev clang-libs \
		bison \
		dpkg-dev dpkg \
		flex \
		gcc \
		libc-dev \
		libedit-dev \
		libxml2-dev \
		libxslt-dev \
		linux-headers \
	 	clang g++ \
		make \
		openssl-dev \
		perl-utils \
		perl-ipc-run \
		util-linux-dev \
		zlib-dev \
		icu-dev

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    RUST_VERSION=1.53.0 \
    # prevents some issues with openssl
    RUSTFLAGS="-C target-feature=-crt-static"

RUN set -eux; \
    apkArch="$(apk --print-arch)"; \
    case "$apkArch" in \
        x86_64) rustArch='x86_64-unknown-linux-musl'; rustupSha256='bdf022eb7cba403d0285bb62cbc47211f610caec24589a72af70e1e900663be9' ;; \
        aarch64) rustArch='aarch64-unknown-linux-musl'; rustupSha256='89ce657fe41e83186f5a6cdca4e0fd40edab4fd41b0f9161ac6241d49fbdbbbe' ;; \
        *) echo >&2 "unsupported architecture: $apkArch"; exit 1 ;; \
    esac; \
    url="https://static.rust-lang.org/rustup/archive/1.24.3/${rustArch}/rustup-init"; \
    wget "$url"; \
    echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal  --component rustfmt --default-toolchain $RUST_VERSION --default-host ${rustArch}; \
    rm rustup-init; \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
    rustup --version; \
    cargo --version; \
    rustc --version;

RUN set -ex \
    && git clone  --branch v1.12 --depth 1 \
         https://github.com/dimitri/pgextwlist.git /pgextwlist \
    && cd /pgextwlist \
    && make \
    && make install \
    && mkdir `pg_config --pkglibdir`/plugins \
    && cp /pgextwlist/pgextwlist.so `pg_config --pkglibdir`/plugins \
    && rm -rf /pgextwlist

USER postgres

RUN set -ex \
    && cargo install cargo-pgx \
    && cargo pgx init --pg14 /usr/local/bin/pg_config

COPY --chown=postgres promscale.control Makefile dependencies.makefile /build/promscale/
COPY --chown=postgres src/*.c src/*.h /build/promscale/src/
COPY --chown=postgres Cargo.* /build/promscale/
COPY --chown=postgres src/*.rs /build/promscale/src/
COPY --chown=postgres sql/*.sql /build/promscale/sql/

RUN set -ex \
    && make -C /build/promscale rust

USER root

RUN set -ex \
    && make -C /build/promscale install

# COPY over the new files to the image. Done as a seperate stage so we don't
# ship the build tools.
FROM timescale/timescaledb:${TIMESCALEDB_VERSION}-${PG_VERSION_TAG}

COPY --from=builder /usr/local/lib/postgresql /usr/local/lib/postgresql
COPY --from=builder /usr/local/share/postgresql /usr/local/share/postgresql
