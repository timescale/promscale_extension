# End-to-end testing

This directory contains end-to-end tests for the promscale extension. Tests can be written in Rust,
or in pure SQL and run as snapshot tests. As the tests run in a Docker container, the `docker` command must be present on the local system.

## Running tests

Run the tests with `cargo test -p e2e`. The tests are run against a docker image. Set the value of
the `TS_DOCKER_IMAGE` env var to override the default docker image, e.g.:

```
TS_DOCKER_IMAGE=ghcr.io/timescale/dev_promscale_extension:develop-ts2-pg13 cargo test -p e2e
```

## Rust tests

Tests of arbitrary complexity can be written in Rust. There is no default setup or teardown, but
tests  can use Docker to start and stop containers. There is not much infrastructure or convention
here yet.

## SQL Snapshot tests

Each `.sql` file in the `testdata` directory is executed as its own test, against a fresh database.
The output of the script is recorded as a snapshot, and compared on the next test run.

To add a new test:
0. (prerequisite) run `cargo install cargo-insta`
1. create a new `.sql` file in the `testdata` directory
2. run the golden tests with `cargo test --test golden-tests`
3. the tests will fail
4. validate that the new snapshot output is as you expect it to be
5. run `cargo insta review` to interactively review the snapshot outputs (or `cargo insta accept` to accept them all) 