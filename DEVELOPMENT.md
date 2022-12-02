# Development

This document covers important topics for contributing to this repository.

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
tests against the container.

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

## Modifying and testing SQL migrations

All SQL source code resides in `./migration` subdirectory. (The `./sql` subdirectory
contains nothing but generated code and symlinks.) Our general approach to writing
migrations is documented [here](./migration/README.md). Please, give it a read before
proceeding further.

### Running SQL tests

After you modified or added migration tests can be executed in the devcontainer
by running `make dev-sql-tests`. Our approach to adding tests is described
[below](#testing).

### Updating public API documentation

Our CI validates `./docs/sql-api.md` is up to date. If you added a new function
you can update the docs by running `make dev-gendoc`.
Note: it relies on the devcontainer.

## Testing

Testing in this repository is split into three different kinds of tests, each
of which are found in their own directory or workspace:

- PGX tests
- End-to-end SQL tests
- End-to-end Rust tests

PGX tests are found in the `src` directory, typically in the same source file
as a function defined in Rust. These tests are solely intended to test the
behaviour of Postgres functions implemented in Rust.

End-to-end SQL tests are found in the `sql-tests` workspace, in the `testdata`
directory. The tests are written in SQL and intended to be used to test
functions we write in SQL (in the `migration` directory), or complex
interactions involving both SQL and native functions. Each SQL file is run
against a test database, but the test has no control over database or
connection creation, so it is not possible to test certain behaviours. For more
information, see the [README](sql-tests/README.md).

End-to-end Rust tests are found in the `e2e` directory. They are intended to
be used as an upgrade to end-to-end SQL tests, as the test has full control
over test setup, and can create multiple connections. For more information,
see the [README](e2e/README.md).

### Which test method to use?

If you're adding a Rust function, use PGX tests. If you're adding/testing a
SQL migration, try to test it with an end-to-end SQL test. If that is not
possible, write it as an end-to-end Rust test.

### Running PGX tests

If you need to modify Rust code you should also run corresponding tests.
Unfortunately, our dev environment doesn't handle this yet.

Firstly, you'll need to install and configure PGX:
- `./install-cargo-pgx.sh`
- `cargo pgx init`

Then you can run PGX tests by executing: `cargo pgx test`. If you need to run
them against a specific PostgreSQL version you can use a corresponding feature
flag: `cargo pgx test pg12`.

### Running end-to-end Rust tests

End-to-end tests rely on a docker image that needs to contain PostgreSQL with both
TimescaleDB and Promscale extensions. You can either obtain that image from CI or
build it yourself: `make docker-image-14` (there are also targets for 12 and 13).

If you have already built a local docker image and your changes are limited to
SQL migrations there is also `make docker-quick-NN` family of targets. It's faster
but could be finicky.

To run the e2e tests against the locally build image run: `cargo test -p e2e`.
Further details could be found in the [corresponding document](./e2e/README.md).

## Known Issues

Older versions of Rust misbehaved on Apple Sillicon during panic unwind. Leading to
errors like `(signal: 11, SIGSEGV: invalid memory reference)` during test failures.
The solution is to upgrade to Rust >1.64 via:
- `rustup toolchain install nightly`
- `rustup default nightly`

## Tips and tricks

Use `RUST_LOG=DEBUG` to get more test output from cargo tests
