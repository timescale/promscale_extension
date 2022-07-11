# Note: in future we should use the timescaledb-ha image. Unfortunately it
# doesn't have arm64 builds, so we're doing things from scratch.
FROM ubuntu:22.04

SHELL ["/bin/bash", "-eE", "-o", "pipefail", "-c"]

RUN apt update && apt install -y sudo wget curl gnupg2 lsb-release

# Setup a non-root user that we'll use
RUN adduser --disabled-password --gecos "" ubuntu && \
 usermod -aG sudo ubuntu && \
 echo "ubuntu ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/ubuntu

ENV DEBIAN_FRONTEND=noninteractive

# Install timescaledb
RUN echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -c -s)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
RUN echo "deb [signed-by=/usr/share/keyrings/timescale.keyring] https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" > /etc/apt/sources.list.d/timescaledb.list
RUN wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /usr/share/keyrings/timescale.keyring
RUN apt-get update && apt-get install -y timescaledb-2-postgresql-{12,13,14}
RUN apt-get install -y build-essential clang libssl-dev pkg-config libreadline-dev zlib1g-dev postgresql-server-dev-{12,13,14}

# These directories need to be writeable for pgx to install the extension into
RUN chmod a+w /usr/share/postgresql/*/extension /usr/lib/postgresql/*/lib

USER ubuntu

# Install rust
ENV RUST_VERSION=1.62.0
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --component rustfmt --default-toolchain ${RUST_VERSION}
ENV PATH=/home/ubuntu/.cargo/bin:$PATH

RUN cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev ee52db6b

RUN cargo pgx init --pg14 /usr/lib/postgresql/14/bin/pg_config --pg13 /usr/lib/postgresql/13/bin/pg_config --pg12 /usr/lib/postgresql/12/bin/pg_config

RUN timescaledb-tune --quiet --yes -conf-path ~/.pgx/data-12/postgresql.conf
RUN timescaledb-tune --quiet --yes -conf-path ~/.pgx/data-13/postgresql.conf
RUN timescaledb-tune --quiet --yes -conf-path ~/.pgx/data-14/postgresql.conf

# Make Postgres accessible from host
RUN sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" ~/.pgx/data-{12,13,14}/postgresql.conf
RUN sed -i "s#127.0.0.1/32#0.0.0.0/0#" ~/.pgx/data-{12,13,14}/pg_hba.conf
# Disable telemetry
RUN echo "timescaledb.telemetry_level=off" | tee -a ~/.pgx/data-{12,13,14}/postgresql.conf

RUN sudo apt-get install -y vim

RUN mkdir -p ~/.cargo
# Make cargo put compile artifacts in non-bind-mounted directory
# To re-use compiled artifacts, mount a docker volume to /tmp/target
RUN echo -e '[build]\ntarget-dir="/tmp/target"' > ~/.cargo/config.toml
# Sources should be bind-mounted to /code/
WORKDIR /code/

RUN sudo apt-get install -y entr
COPY devenv.sh /usr/local/bin/
CMD ["devenv.sh"]


