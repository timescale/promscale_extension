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

To compile and install from source follow the steps:
1) [Install rust](https://www.rust-lang.org/tools/install).
1) Install our fork of the PGX framework `cargo install --git https://github.com/JLockerman/pgx.git --branch timescale cargo-pgx && cargo pgx init`  
1) Compile and install: `make && make install`.

This extension will be created via `CREATE EXTENSION` automatically by the Promscale connector and should not be created manually.

## Common Compilation Issues ##

- `cargo: No such file or directory` means the [Rust compiler](https://www.rust-lang.org/tools/install) is not installed
