# End-to-end testing

This directory contains end-to-end tests for the promscale extension. Tests should be written in Rust.
As the tests run in a Docker container, the `docker` command must be present on the local system.

## Running tests

Run the tests with `cargo test -p e2e`. The tests are run against a docker image. Set the value of
the `TS_DOCKER_IMAGE` env var to override the default docker image, e.g.:

```
TS_DOCKER_IMAGE=ghcr.io/timescale/dev_promscale_extension:master-ts2-pg13 cargo test -p e2e
```

## Rust tests

Tests of arbitrary complexity can be written in Rust. There is no default setup or teardown, but
tests can use Docker to start and stop containers. There is not much infrastructure or convention
here yet.