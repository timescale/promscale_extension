# Continuous integration setup

### File: `lint.yaml`
A workflow that runs `cargo fmt`, `clippy` on Rust codebase and `pgspot` on SQL
migrations. Each linter runs as a separate job with a corresponding name.

### File: `ci.yaml`
Contains just one job `test` that executes Rust/PGX unit tests on a matrix of
supported PostgreSQL versions.

### File: `docker.yaml`

Quite a lot is going on in this one. The `docker` job goes first. It builds docker
images for the `(pgversion x tsversion x base)` matrix. The base is either `ha.Dockerfile`,
that builds on top of `timescale/timescaledb-ha` or `alpine.Dockerfile`, which
is maintained for legacy reasons and because it's quicker to build in local
development. The resulting images are pushed to `ghcr.io/timescale/dev_promscale_extension`
Then each image is validated by running [`e2e` suite](../e2e/README.md) of this repository.
And the last step of the `docker` job validates that there are no undocumented API changes.

The next job is a helper that determines whether `timescale/promscale` repo has a branch
with the same name as the current branch, or defaults to `master`.

`call-connector-e2e` job embeds and executes the `go-e2e.yml` workflow from
`timescale/promscale` repo. The workflow checks out `promscale` repo and branch, picked
by the previous job, then executes `promscale` `e2e` suite against the HA image built
by `docker` job.

Finally, `docker-result` job aggregates the results of all other jobs and is used to
signal the overall status of this workflow to GitHub checks.


### File: `release.yaml`

This workflow builds packages for a pretty hairy matrix of `(arch x os x postgres)`.
At the moment only x86_64 arch is supported. The OS, in the end, is merely a synonym
for a Linux distribution and the only actual distinction is made between `.deb` and `.rpm`.

Only pushes to main and new tags trigger this workflow.

The workflow contains two jobs:
 - `package` builds packages using `dist/*.dockerfile`, extracts it from within a builder container. Then it tests the resulting packages using `dist/*.test.dockerfile` and `tools/smoke-test`. Finally tested artifacts are uploaded to GitHub and PackageCloud.
 - `release` collects artifacts, release notes and creates a GitHub release.