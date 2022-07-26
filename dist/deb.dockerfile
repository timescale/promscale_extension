# syntax=docker/dockerfile:1.3-labs

## Build base system
ARG OS_NAME=debian
ARG OS_VERSION=11
ARG PG_VERSION
FROM ${OS_NAME}:${OS_VERSION} as base

SHELL ["/bin/bash", "-eu", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Setup base system
RUN <<EOF
export OS_NAME="$(source /etc/os-release; echo "${ID}")"
export OS_VERSION="$(source /etc/os-release; echo "${VERSION_ID}")"

apt-get update -y

apt-get install -y \
    cmake \
    gcc \
    make \
    apt-transport-https \
    build-essential \
    software-properties-common \
    debhelper \
    devscripts \
    wget \
    curl \
    openssl \
    libssl-dev \
    tzdata \
    fakeroot \
    git \
    lintian \
    pkg-config \
    rubygems

# Install FPM
gem install fpm

# Install JQ
curl --proto '=https' --tlsv1.2 -sSLfO https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
mv jq-linux64 /usr/local/bin/jq
chmod +x /usr/local/bin/jq
EOF

RUN <<EOF
    curl -L "https://github.com/mozilla/sccache/releases/download/v0.2.15/sccache-v0.2.15-x86_64-unknown-linux-musl.tar.gz" | tar zxf -
    chmod +x sccache-*/sccache
    mv sccache-*/sccache /usr/local/bin/sccache
    sccache --show-stats
EOF

# Setup postgres separately from the base image for better caching
FROM base AS base-postgres
ARG PG_VERSION

RUN <<EOF
export OS_CODENAME="$(source /etc/os-release; echo "${VERSION_CODENAME}")"

# Install supported Postgres versions
echo "deb http://apt.postgresql.org/pub/repos/apt/ ${OS_CODENAME}-pgdg main" >> /etc/apt/sources.list.d/pgdg.list
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
apt-get update -y

apt-get install -y \
    postgresql-server-dev-${PG_VERSION} \
    postgresql-${PG_VERSION}

# User with which package builds will run
useradd --uid 1000 -m -d /home/builder -s /bin/bash builder

# Create directory in which output artifacts can be dropped
mkdir -p /dist
chmod a+rw /dist
EOF

## Build extension
FROM base-postgres AS builder
ARG PG_VERSION
ARG RUST_VERSION

USER builder
WORKDIR /home/builder
ENV HOME=/home/builder \
    PATH=/home/builder/.cargo/bin:${PATH}

# Install Rust
RUN <<EOF
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION
rustup --version
rustc --version
cargo --version
EOF

ENV RUSTC_WRAPPER=sccache
ENV SCCACHE_BUCKET=promscale-extension-sccache

COPY install-cargo-pgx.sh /usr/local/bin

# Initialize PGX
RUN --mount=type=secret,uid=1000,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=1000,id=AWS_SECRET_ACCESS_KEY <<EOF
[ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)"
[ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)"
sccache --show-stats
install-cargo-pgx.sh
cargo pgx init --pg${PG_VERSION} /usr/lib/postgresql/${PG_VERSION}/bin/pg_config
sccache --show-stats
EOF

FROM builder AS packager
ARG PG_VERSION
ARG RELEASE_FILE_NAME

COPY --chown=builder . .

# Build extension
RUN --mount=type=secret,uid=1000,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=1000,id=AWS_SECRET_ACCESS_KEY <<EOF
[ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)"
[ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)"
sccache --show-stats
tools/package --lint --pg-version ${PG_VERSION} --out-dir /dist --package-name "${RELEASE_FILE_NAME}"
sccache --show-stats

# Clean up build artifacts
rm -rf target/
rm -rf .cargo/
EOF
