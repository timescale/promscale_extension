# Releasing the Promscale extension

The following are step-by-step instructions for releasing the Promscale extension.

## Create an issue to track the release

Create a new issue titled "Release `<version to be released here>`". Copy everything below this line into that issue, and use it to keep track of the release tasks.

---

## Pre-release
- [ ] Create a git branch named `pre-release-x.x.x`
- [ ] Ensure `upgradeable_from` in `templates/promscale.control` contains the previously released version.
- [ ] Update `CHANGELOG.md` with release version and date, ensuring that all relevant changes are reflected.
- [ ] Update the version in all places with `./update-version.sh <version-here>`
- [ ] Freeze any new incremental sql scripts released in this version in `incremental_freeze_test`
- [ ] Create a PR from the `pre-release-x.x.x` branch. Get it approved. Merge the PR to master.

## Release
- [ ] [Create a draft release in GitHub](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository) off the master branch with a new Tag pointing to the version
- [ ] CI will trigger and create a draft release with assets attached.
- [ ] Prepare extension release notes, share with team asking for feedback.
- [ ] Attach release notes to draft release created above.
- [ ] Publish the GitHub release.
- [ ] Wait for CI to generate the packages files
- [ ] Create a PR to update the HA image in [timescaledb-docker-ha](https://github.com/timescale/timescaledb-docker-ha). [EXAMPLE](https://github.com/timescale/timescaledb-docker-ha/pull/285/files)
- [ ] In the timescaledb-docker-ha repo, update `TIMESCALE_PROMSCALE_EXTENSIONS` in the `Makefile` to include the version just released
- [ ] Update the CHANGELOG entry in the timescaledb-docker-ha repo and wait for the CI to complete and request review from the Cloud team and merge it when approved.
- [ ] Create a new PR in the timescaledb-docker-ha repo. Stamps the version in the CHANGELOG. Merge it with master and push the correct tag to trigger CI ([see instructions in the repo](https://github.com/timescale/timescaledb-docker-ha#release-process)) [EXAMPLE](https://github.com/timescale/timescaledb-docker-ha/pull/286/files)


## Post-Release
- [ ] Create a new git branch named `post-release-x.x.x`
- [ ] Run `make post-release` which will generate the `sql/promscale--x.x.x.sql` file of the version just released and create all the upgrade path sql files.
- [ ] Add and commit the newly created sql files to git. They are ignored by default. e.g. `git add sql/*--0.5.5.sql --force`
- [ ] Determine the develop version (determined by bumping the patch version and appending `-dev`)
- [ ] Set the version in all places necessary with `./update-version.sh <develop-version>`
- [ ] Update `upgradeable_from` in templates/promscale.control to add the previously released version
- [ ] Update `e2e/tests/config/mod.rs` to refer to the new docker images
- [ ] Create a PR and get it merged
- [ ] Bump the version in the promscale repo's `EXTENSION_VERSION` file to the version just released (Renovate should automatically create a PR for this).
