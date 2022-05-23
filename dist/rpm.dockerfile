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
    gettext \
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

# Use UTFF-8 as the locale
localedef -f UTF-8 -i en_US en_US.UTF-8

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

ENV LANG=en_US.UTF-8

# Setup postgres separately from the base image for better caching
FROM base AS base-postgres
ARG PG_VERSION

RUN <<EOF
export OS_NAME="$(source /etc/os-release; echo "${ID}")"
export OS_VERSION="$(source /etc/os-release; echo "${VERSION_ID}")"

export PG_ARCH
case "$(uname -m)" in
    amd64|x86_64)
        PG_ARCH=x86_64
        ;;

    arm64|aarch64)
        PG_ARCH=aarch64
        ;;
    *)
        echo "Unsupported architecture! Expected one of amd64,x86_64,arm64,aarch64"
        exit 2
        ;;
esac

PG_REPO=
if [ "${OS_NAME}" = "fedora" ]; then
    PG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/F-${OS_VERSION}-${PG_ARCH}/pgdg-fedora-repo-latest.noarch.rpm"
else
    PG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/EL-${OS_VERSION}-${PG_ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
fi

# Install supported Postgres versions
yum install -y "${PG_REPO}"
yum install -y \
    sudo \
    postgresql${PG_VERSION}-server \
    postgresql${PG_VERSION}-devel
EOF

## Build extension
FROM base-postgres AS builder
ARG PG_VERSION
ARG RUST_VERSION

RUN <<EOF
# User with which package builds will run
useradd --uid 1000 -m -d /home/builder -s /bin/bash builder

# Create directory in which output artifacts can be dropped
mkdir -p /dist
chmod a+rw /dist
EOF

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

# Initialize PGX
RUN --mount=type=secret,uid=1000,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=1000,id=AWS_SECRET_ACCESS_KEY <<EOF
[ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)"
[ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)"
sccache --show-stats
cargo install cargo-pgx --git https://github.com/tcdi/pgx --branch hang-onto-libraries
cargo pgx init --pg${PG_VERSION} /usr/pgsql-${PG_VERSION}/bin/pg_config
sccache --show-stats
EOF

FROM builder AS packager
ARG PG_VERSION

COPY --chown=builder . .

# Package extension
RUN --mount=type=secret,uid=1000,id=AWS_ACCESS_KEY_ID --mount=type=secret,uid=1000,id=AWS_SECRET_ACCESS_KEY <<EOF
[ -f "/run/secrets/AWS_ACCESS_KEY_ID" ] && export AWS_ACCESS_KEY_ID="$(cat /run/secrets/AWS_ACCESS_KEY_ID)"
[ -f "/run/secrets/AWS_SECRET_ACCESS_KEY" ] && export AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/AWS_SECRET_ACCESS_KEY)"
sccache --show-stats
tools/package --pg-version ${PG_VERSION} --out-dir /dist
sccache --show-stats

# Clean up build artifacts
rm -rf target/
rm -rf .cargo/
EOF
