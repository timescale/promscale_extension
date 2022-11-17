# syntax=docker/dockerfile:1.3-labs
ARG DOCKER_DISTRO_NAME
ARG DISTRO
ARG DISTRO_VERSION
FROM ${DOCKER_DISTRO_NAME}:${DISTRO_VERSION} as base

ARG PG_VERSION
ARG RELEASE_FILE_NAME

# Used to provide SCL packages to all noninteractive, non-login shells when present
ENV BASH_ENV=/etc/scl_enable

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN <<EOF
export OS_NAME="$(source /etc/os-release; echo "${ID}")"
export OS_VERSION="$(source /etc/os-release; echo "${VERSION_ID}" | cut -d. -f 1)"

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

PG_REPO="https://download.postgresql.org/pub/repos/yum/reporpms/EL-${OS_VERSION}-${PG_ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
yum install -y "${PG_REPO}"

case "${OS_VERSION}" in
    7)
        yum install -y epel-release scl-utils centos-release-scl centos-release-scl-rh
        ;;
    8)
        # Disable postgres
        yum module -y disable postgresql
        ;;
esac

yum install -y \
    sudo \
    postgresql${PG_VERSION}-server \
    postgresql${PG_VERSION}-devel

    tee /etc/yum.repos.d/timescale_timescaledb.repo <<EOL
[timescale_timescaledb]
name=timescale_timescaledb
baseurl=https://packagecloud.io/timescale/timescaledb/el/${OS_VERSION}/\$basearch
repo_gpgcheck=1
gpgcheck=0
enabled=1
gpgkey=https://packagecloud.io/timescale/timescaledb/gpgkey
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
EOL

EOF

# Install timescaledb
RUN yum update -y && yum install -y timescaledb-2-postgresql-${PG_VERSION}

# Install the Promscale extension
COPY ${RELEASE_FILE_NAME} /var/lib/pgsql/
RUN rpm -i "/var/lib/pgsql/$(basename ${RELEASE_FILE_NAME})"

RUN sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/pgsql-${PG_VERSION}/share/postgresql.conf.sample
RUN sed -ri "s!^logging_collector!#logging_collector!" /usr/pgsql-${PG_VERSION}/share/postgresql.conf.sample
RUN echo "shared_preload_libraries = 'timescaledb'" >> /usr/pgsql-${PG_VERSION}/share/postgresql.conf.sample

COPY --chown=postgres dist/tester/entrypoint /usr/local/bin/entrypoint

USER postgres

WORKDIR /var/lib/pgsql-${PG_VERSION}
ENV PGDATA=/var/lib/pgsql/${PG_VERSION}/data \
    PATH=/usr/pgsql-${PG_VERSION}/bin:$PATH

# Initialize Postgres data directory
RUN <<EOF
initdb --username=postgres --pwfile=<(echo 'postgres') "${PGDATA}"

timescaledb-tune -quiet -yes
EOF

# Listen on 5432 by default
EXPOSE 5432
# Postgres responds to SIGINT with a fast shutdown
STOPSIGNAL SIGINT

ENTRYPOINT ["entrypoint"]
CMD ["postgres"]
