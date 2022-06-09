# Promscale Extension

This [Postgres extension](https://www.postgresql.org/docs/12/extend-extensions.html)
contains support functions to improve the performance of Promscale.

Promscale 0.11.0 and higher require that the Promscale extension is installed.
Check the [release notes](https://github.com/timescale/promscale/releases/) for more details.

## Requirements

To run the extension:

- PostgreSQL version 12 or newer.

To compile the extension (see instructions below):

- Rust compiler
- PGX framework

## Installation

### Precompiled OS Packages

You can install the Promscale extension using precompiled packages for Debian and RedHat-based distributions (RHEL-7 only). 

The packages can be found in the Timescale [repository](https://packagecloud.io/app/timescale/timescaledb/search?q=promscale-extension). 

While the extension declares a dependency on Postgres 12-14, it can be run on TimescaleDB 2.x as well, which fulfills the requirement
on Postgres indirectly. You can find the installation instructions for TimescaleDB [here](https://docs.timescale.com/install/latest/self-hosted/)

#### Debian Derivatives

1. Install Postgres or TimescaleDB
   Instructions for installing TimescaleDB and Postgres can be found [here](https://docs.timescale.com/install/latest/self-hosted/installation-debian/#install-self-hosted-timescaledb-on-debian-based-systems), and [here](https://www.postgresql.org/download/) respectively. 

3. Install the Promscale extension
    ```
    wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | apt-key add -
    apt update
    apt install promscale-extension-postgresql-14
    ```

#### RHEL/CentOS

See the Postgres [documentation](https://www.postgresql.org/download/linux/redhat/) for more information.

1. Install TimescaleDB or Postgres
   Instructions for installing TimescaleDB and Postgres can be found [here](https://docs.timescale.com/install/latest/self-hosted/installation-debian/#install-self-hosted-timescaledb-on-debian-based-systems), and [here](https://www.postgresql.org/download/) respectively.

2. Install the extension (on CentOS 7)
    ```
    yum install https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{centos})-x86_64/pgdg-redhat-repo-latest.noarch.rpm
    tee /etc/yum.repos.d/timescale_timescaledb.repo <<EOL
    [timescale_timescaledb]
    name=timescale_timescaledb
    baseurl=https://packagecloud.io/timescale/timescaledb/el/$(rpm -E %{rhel})/\$basearch
    repo_gpgcheck=1
    gpgcheck=0
    enabled=1
    gpgkey=https://packagecloud.io/timescale/timescaledb/gpgkey
    sslverify=1
    sslcacert=/etc/pki/tls/certs/ca-bundle.crt
    metadata_expire=300
    EOL
    yum update
    yum install -y promscale-extension-postgresql-14
    ```

### Docker images

- [Official HA](https://hub.docker.com/r/timescale/timescaledb-ha). This very image is available at Timescale Cloud. They are updated along with tagged releases.
- HA-based CI image - used in the GitHub Actions CI pipeline. Use at your own peril. It could be handy to play with pre-release versions. 
- `alpine` - legacy and local development -- Avoid if you can. It will eat your ~laundry~ collation.
- `quick` and package building images are not published anywhere and are used for local development and building packages 

### Compile From Source

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
    cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging
    ```
1) Initialize the PGX framework using the PostgreSQL 14 installation
    ```bash
    cargo pgx init --pg14=/usr/lib/postgresql/14/bin/pg_config
    ```
1) Download this repo and change directory into it
    ```bash
    sudo apt-get install -y git
    git clone https://github.com/timescale/promscale_extension
    cd promscale_extension
    git checkout 0.5.0
    ```
1) Compile and install
    ```bash
    make package
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

## Common Compilation Issues

- `cargo: No such file or directory` means the [Rust compiler](https://www.rust-lang.org/tools/install) is not installed

## Development

To understand more about how to write SQL migration files for this extension, consult [this](migration/README.md) guide.
To get a better understanding of our CI pipeline see [this document](.github/README.md).
