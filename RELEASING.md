# Releasing the Promscale extension

The following are step-by-step instructions for releasing the Promscale extension.

## Pre-release
- [ ] Ensure `upgradeable_from` in `templates/promscale.control` contains the previously released version.
- [ ] Update `CHANGELOG.md` with release version and date.
- [ ] Update the extension version in `Cargo.toml`, don't forget to fix the `.so` references in `incremental/001-extension.sql`, `idempotent/014-extension-type-functions.sql`, and `promscale--0.0.0.sql`.
- [ ] Freeze the versions of SQL scripts in `incremental_freeze_test`
- [ ] Update the extension tag in the _Compile From Source_ instructions.
- [ ] Merge release commit.

## Release
- [ ] Tag and push merged release commit.
  - CI will trigger and create a draft release with assets attached.
- [ ] Prepare extension release notes, share with team asking for feedback.
- [ ] Manually tag and push `timescaledev/promscale-extension` docker image (see #354)
- [ ] Attach release notes to draft release created above.
- [ ] Publish the GitHub release

## Post-Release
- [ ] Prepare for the next development cycle:
  - Generate SQL schema and commit it (and upgrade symlinks to it) to the `sql` directory.
  - Bump the patch version in `Cargo.toml`, and fix the `.so` references in `incremental/001-extension.sql`, `idempotent/014-extension-type-functions.sql`, and `promscale--0.0.0.sql`.
  - Update `upgradeable_from` in templates/promscale.control to add the previously released version
- [ ] Bump the version in Promscale's `EXTENSION_VERSION` (Renovate should automatically create a PR for this).
- [ ] Add the new version to `timescaledb/timescaledb-docker-ha` docker image.
