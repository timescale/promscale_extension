# syntax=docker/dockerfile:1.3-labs

## Build base system
ARG OS_NAME=centos
ARG OS_VERSION=8
FROM ${OS_NAME}:${OS_VERSION} as base

# Used to provide SCL packages to all noninteractive, non-login shells when present
ENV BASH_ENV=/etc/scl_enable

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Setup base system
RUN <<EOF
export OS_NAME="$(source /etc/os-release; echo "${ID}")"
export OS_VERSION="$(source /etc/os-release; echo "${VERSION_ID}")"

yum update -y

# Version-specific dependencies
case "${OS_VERSION}" in
    7)
        yum install -y epel-release scl-utils centos-release-scl centos-release-scl-rh
        yum install -y rh-ruby23 llvm-toolset-7
        # Activate rh-ruby23 and llvm-toolset-7 in the current shell session
        set +u
        source /opt/rh/rh-ruby23/enable
        source /opt/rh/llvm-toolset-7/enable
        set -u
        # Ensure rh-ruby23 and llvm-toolset-7 are activated in any new shells
        echo '#!/bin/bash' > /etc/scl_enable
        echo 'set +u' >> /etc/scl_enable
        echo 'unset BASH_ENV PROMPT_COMMAND ENV' >> /etc/scl_enable
        echo 'source scl_source enable rh-ruby23 llvm-toolset-7' >> /etc/scl_enable
        chmod a+x /etc/scl_enable
        ;;
    8|9)
        yum install -y epel-release rubygems ruby-devel
        ;;
    *)
        if [ "${OS_NAME}" = "fedora" ]; then
            yum install -y rubygems ruby-devel
        else
            yum install -y epel-release rubygems ruby-devel
        fi
        ;;
esac

# Disable postgres
if command -v dnf; then dnf -qy module disable postgresql; fi

# System dependencies
yum install -y \
    rpm-build \
    rpm-devel \
    rpmlint \
    rpmdevtools \
    gcc \
    make \
    wget \
    curl \
    openssl \
    openssl-devel \
    bash \
    diffutils \
    git

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
export OS_NAME="$(source /etc/os-release; echo "${ID}")"
export OS_VERSION="$(source /etc/os-release; echo "${VERSION_ID}")"

PG_REPO=
if [ "${OS_NAME}" = "fedora" ]; then
    PG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/F-${OS_VERSION}-x86_64/pgdg-fedora-repo-latest.noarch.rpm"
else
    PG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/EL-${OS_VERSION}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
fi

# Install supported Postgres versions
yum install -y "${PG_REPO}"
yum install -y \
    postgresql${PG_VERSION}-server \
    postgresql${PG_VERSION}-devel

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
cargo install cargo-pgx
cargo pgx init --pg${PG_VERSION} /usr/pgsql-${PG_VERSION}/bin/pg_config
EOF

FROM builder AS packager
ARG PG_VERSION

COPY --chown=builder . .

# Build extension
RUN <<EOF
tools/package --pg-version ${PG_VERSION} --out-dir /dist

# Clean up build artifacts
rm -rf target/
rm -rf .cargo/
EOF
