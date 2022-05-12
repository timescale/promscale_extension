# syntax=docker/dockerfile:1.3-labs
ARG OS_NAME=centos
ARG OS_VERSION=7
FROM ${OS_NAME}:${OS_VERSION} as base

ARG PG_VERSION
ARG RELEASE_FILE_NAME

# Used to provide SCL packages to all noninteractive, non-login shells when present
ENV BASH_ENV=/etc/scl_enable

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install and setup postgres repos
RUN yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{centos})-x86_64/pgdg-redhat-repo-latest.noarch.rpm
COPY dist/tester/timescale_timescaledb.repo /etc/yum.repos.d/

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
