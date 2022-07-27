# SQL test

This directory contains SQL tests for the promscale extension. Tests must be written in SQL and
the usage of `pgtap.sql` is highly encouraged.

## Running tests

Run the tests with `cargo test -p sql-tests`.  By default, the tests are run
against `localhost:5432`. You can override it either by specifying
`POSTGRES_URL` or a combination of `POSTGRES_USER`, `POSTGRES_HOST`, `POSTGRES_PORT`
and `POSTGRES_DB` environment variables.

```
POSTGRES_URL=postgres://ubuntu@localhost:54321/ cargo test -p sql-tests
```

or

```
POSTGRES_USER=postgres POSTGRES_HOST=localhost POSTGRES_PORT=5432 cargo test -p sql-tests
```

To run the tests against a docker image set the value of the `TS_DOCKER_IMAGE` to the desired docker image, e.g.:

```
TS_DOCKER_IMAGE=ghcr.io/timescale/dev_promscale_extension:master-ts2-pg13 cargo test -p sql-tests
```

## SQL Snapshot tests

Each `.sql` file in the `testdata` directory is executed as its own test, against a fresh database.
The output of the script is recorded as a snapshot, and compared on the next test run.

To add a new test:
0. (prerequisite) run `cargo install cargo-insta`
1. create a new `.sql` file in the `testdata` directory
2. run the tests with `cargo test -p sql-tests`
3. the tests will fail
4. validate that the new snapshot output is as you expect it to be
5. run `cargo insta review` to interactively review the snapshot outputs (or `cargo insta accept` to accept them all) 