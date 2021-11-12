# Promscale Extension #

This [Postgres extension](https://www.postgresql.org/docs/12/extend-extensions.html)
contains support functions to improve the performance of Promscale.
While Promscale will run without it, adding this extension will
cause it to perform better.

## Requirements ##

To run the extension:
- PostgreSQL version 12 or newer.

To compile the extension (see instructions below):
- Rust compiler
- PGX framework

## Installation ##

The extension is installed by default on the
[`timescaledev/promscale-extension:latest-pg12`](https://hub.docker.com/r/timescaledev/promscale-extension) docker image.

For bare-metal installations, the full instructions for setting up PostgreSQL, TimescaleDB, and the Promscale Extension are:

1) Install some necessary dependencies
    ```bash
    sudo apt-get install -y wget curl gnupg2 lsb-release
    ```
1) [Add the PostgreSQL APT repository (Ubuntu)](https://www.postgresql.org/download/linux/ubuntu/)
    ```bash
    echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -c -s)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
    ```
1) Add the TimescaleDB APT repository
    ```bash
    echo "deb [signed-by=/usr/share/keyrings/timescale.keyring] https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" | sudo tee /etc/apt/sources.list.d/timescaledb.list
    wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/timescale.keyring
    ```
1) Install PostgreSQL with TimescaleDB
    ```bash
    sudo apt-get update
    sudo apt-get install -y timescaledb-2-postgresql-14
    ```
1) Tune the PostgreSQL installation
    ```bash
    sudo timescaledb-tune --quiet --yes
    sudo service postgresql restart
    ```
1) Install dependencies for the PGX framework and promscale_extension
    ```bash
    sudo apt-get install -y build-essential clang libssl-dev pkg-config libreadline-dev zlib1g-dev postgresql-server-dev-14
    ```
1) [Install rust](https://www.rust-lang.org/tools/install).
    ```bash
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    source $HOME/.cargo/env
    ```
1) Install the PGX framework
    ```bash
    cargo install cargo-pgx
    ```
1) Initialize the PGX framework using the PostgreSQL 14 installation
    ```bash
    cargo pgx init --pg14=/usr/lib/postgresql/14/bin/pg_config
    ```
1) Download this repo and change directory into it
    ```bash
    curl -L -o "promscale_extension.zip" "https://github.com/timescale/promscale_extension/archive/refs/tags/0.3.0.zip"
    sudo apt-get install unzip
    unzip promscale_extension.zip
    cd promscale_extension-0.3.0
    ```
1) Compile and install
    ```bash
    make
    sudo make install
    ```
1) Create a PostgreSQL user and database for promscale (use an appropriate password!)
    ```bash
    sudo -u postgres psql -c "CREATE USER promscale SUPERUSER PASSWORD 'promscale';"
    sudo -u postgres psql -c "CREATE DATABASE promscale OWNER promscale;"
    ```
1) [Download and run promscale (it will install the extension in the PostgreSQL database)](https://github.com/timescale/promscale/blob/master/docs/bare-metal-promscale-stack.md#2-deploying-promscale)
    ```bash
    LATEST_VERSION=$(curl -s https://api.github.com/repos/timescale/promscale/releases/latest | grep "tag_name" | cut -d'"' -f4)
    curl -L -o promscale "https://github.com/timescale/promscale/releases/download/${LATEST_VERSION}/promscale_${LATEST_VERSION}_Linux_x86_64"
    chmod +x promscale
    ./promscale --db-name promscale --db-password promscale --db-user promscale --db-ssl-mode allow --install-extensions
    ```

This extension will be created via `CREATE EXTENSION` automatically by the Promscale connector and should not be created manually.

## Common Compilation Issues ##

- `cargo: No such file or directory` means the [Rust compiler](https://www.rust-lang.org/tools/install) is not installed
