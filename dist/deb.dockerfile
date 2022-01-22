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

if [ "${OS_VERSION}" = "9" ]; then
    echo "deb http://deb.debian.org/debian stretch-backports main" >> /etc/apt/sources.list.d/backports.list
    echo "deb http://deb.debian.org/debian stretch-backports-sloppy main" >> /etc/apt/sources.list.d/backports.list
    apt-get update -y
    apt-get -t stretch-backports-sloppy install -y libarchive13
    apt-get -t stretch-backports install -y cmake gcc make
else
    apt-get update -y
    apt-get install -y cmake gcc make
fi

apt-get install -y \
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
useradd -m -d /home/builder -s /bin/bash builder

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

# Initialize PGX
RUN <<EOF
cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging
cargo pgx init --pg${PG_VERSION} /usr/lib/postgresql/${PG_VERSION}/bin/pg_config
EOF

FROM builder AS packager
ARG PG_VERSION
ARG RELEASE_FILE_NAME

COPY --chown=builder . .

# Build extension
RUN <<EOF
tools/package --lint --pg-version ${PG_VERSION} --out-dir /dist --package-name "${RELEASE_FILE_NAME}"

# Clean up build artifacts
rm -rf target/
rm -rf .cargo/
EOF

FROM postgres:${PG_VERSION} AS tester
ARG PG_VERSION
ARG RELEASE_FILE_NAME

SHELL ["/bin/bash", "-eE", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Install TimescaleDB, as required by Promscale
RUN <<EOF
apt-get update -y && apt-get install -y curl

export OS_CODENAME="$(source /etc/os-release; echo "${VERSION_CODENAME}")"
echo "deb https://packagecloud.io/timescale/timescaledb/debian/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/timescaledb.list

curl --proto '=https' --tlsv1.2 -sSLf https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add -

apt-get update -y && apt-get install -y "timescaledb-2-postgresql-${PG_VERSION}"

echo '#/bin/bash' >> /docker-entrypoint-initdb.d/99-timescaledb-tune.sh
echo 'set -e' >> /docker-entrypoint-initdb.d/99-timescaledb-tune.sh
echo 'timescaledb-tune -quiet -yes' >> /docker-entrypoint-initdb.d/99-timescaledb-tune.sh
EOF

# Install the Promscale extension
COPY --from=packager /dist/${RELEASE_FILE_NAME} /var/lib/postgresql/

RUN dpkg -i "/var/lib/postgresql/${RELEASE_FILE_NAME}"
