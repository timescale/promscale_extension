# syntax=docker/dockerfile:1.3-labs
ARG DOCKER_DISTRO_NAME
ARG DISTRO
ARG DISTRO_VERSION
FROM ${DOCKER_DISTRO_NAME}:${DISTRO_VERSION}

ARG PG_VERSION
ARG RELEASE_FILE_NAME

SHELL ["/bin/bash", "-eE", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Install and setup postgres repos
RUN apt-get update && apt-get install -y gnupg postgresql-common apt-transport-https lsb-release wget
RUN yes | /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh || true

# Install timescaledb
RUN sh -c "echo 'deb https://packagecloud.io/timescale/timescaledb/$(lsb_release -i -s | awk '{print tolower($0)}')/ $(lsb_release -c -s) main' > /etc/apt/sources.list.d/timescaledb.list"
RUN wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add -
RUN apt-get update && apt-get install -y "timescaledb-2-postgresql-${PG_VERSION}"

RUN sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/share/postgresql/${PG_VERSION}/postgresql.conf.sample
RUN echo "shared_preload_libraries = 'timescaledb'" >> /usr/share/postgresql/${PG_VERSION}/postgresql.conf.sample

# Install the Promscale extension
COPY ${RELEASE_FILE_NAME} /var/lib/postgresql/
RUN dpkg -i "/var/lib/postgresql/$(basename ${RELEASE_FILE_NAME})"

COPY --chown=postgres dist/tester/entrypoint /usr/local/bin/entrypoint

USER postgres

WORKDIR /var/lib/postgresql/${PG_VERSION}/
ENV PGDATA=/var/lib/postgresql/${PG_VERSION}/data \
    PATH=/usr/lib/postgresql/${PG_VERSION}/bin:$PATH

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
