# Development

This document covers important topics for developing in this repository.

## Development environment

In order to get started developing the extension, you need a postgres install
with timescaledb, and Rust dependencies. For more information, see the
[compile from source](INSTALL.md#Compile From Source) install instructions.

To spare you the effort of getting this set up yourself, we provide a docker
image with all required dependencies, which allows you to just get started.
Although, `make` and `cargo` have to be installed on the host system nonetheless.

Run `make devenv` to build the docker image, start it, and expose it on port
54321 on your local machine. This docker image mounts the current directory
into the `/code` directory in the container. By default, it runs postgres 14
and continually recompiles and reinstalls the promscale extension on source
modifications. This means that you can edit the sources locally, and run SQL 
tests against the container: `make sql-tests`.

You can adjust the postgres version through the `DEVENV_PG_VERSION` env var,
for example: `DEVENV_PG_VERSION=12 make devenv`

The `POSTGRES_URL` environment variable is used by tests and tools in this repo
to point to a specific postgres installation. If you want to use the image
above, set `POSTGRES_URL=postgres://ubuntu@localhost:54321/`.

The `devenv-url` and `devenv-export-url` make targets output the URL above in
convenient formats, for example:

- To connect to the devenv db with psql: `psql $(make devenv-url)`
- To set the `POSTGRES_URL` for all subshells: `eval $(make devenv-export-url)`

To permanently configure `POSTGRES_URL` when you change into this directory,
you may consider using a tool like [direnv](https://direnv.net/).

## Updating public API documentation

Our CI validates `./docs/sql-api.md` is up to date. If you added a new function
you can update it by running `make gendoc`. By default it will use the devenv container.

## Testing

Testing in this repository is split into three different kinds of tests, each
of which are found in their own directory or workspace:

- pgx tests
- End-to-end SQL tests
- End-to-end Rust tests

pgx tests are found in the `src` directory, typically in the same source file
as a function defined in Rust. These tests are solely intended to test the
behaviour of Postgres functions implemented in Rust.

End-to-end SQL tests are found in the `sql-tests` workspace, in the `testdata`
directory. The tests are written in SQL and intended to be used to test
functions which we write in SQL (in the `migration` directory), or complex
interactions involving both SQL and native functions. Each SQL file  is run
against a test database, but the test has no control over database or
connection creation, so it is not possible to test certain behaviours. For more
information, see the [README](sql-tests/README.md).

End-to-end Rust tests are found in the `e2e` directory. They are intended to
be used as an upgrade to end-to-end SQL tests, as the test has full control
over test setup, can create multiple connections. For more information, see the
[README](e2e/README.md).

### Which test method to use?

If you're adding a Rust function, use pgx tests. If you're adding/testing a
SQL migration, try to test it with an end-to-end SQL test. If that is not
possible, write it as an end-to-end Rust test.


### Running PGX tests

If you need to modify Rust code you should also run corresponding tests.
Unfortunately, our dev environment doesn't handle this yet.

Firstly, you'll need to install and configure PGX:
- `cargo install cargo-pgx --git https://github.com/timescale/pgx --branch promscale-staging --rev ee52db6b` (the branch and rev are subject to change)
- `cargo pgx init`

Then you can run PGX tests by executing: `cargo pgx test`. If you need to run
them against a specific PostgreSQL version you can use a corresponding feature 
flag: `cargo pgx test pg12`.