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
- [ ] Attach release notes to draft release created above.
- [ ] Publish the GitHub release.

## Post-Release
- [ ] Prepare for the next development cycle:
  - Generate SQL schema and commit it (and upgrade symlinks to it) to the `sql` directory.
<details>
<summary>Examples</summary>

Generate SQL file:

```bash
cargo pgx schema --release
mv sql/promscale-0.5.5.sql sql/promscale--0.5.5.sql
```

Create symlinks:

```bash
./create-upgrade-symlinks.sh
```

Force add the `.sql` files to the commit, as they're in `.gitignore`:

```bash
git add sql/*--0.5.5*.sql --force
```
</details>

  - Bump the patch version in `Cargo.toml`, and fix the `.so` references in `incremental/001-extension.sql`, `idempotent/014-extension-type-functions.sql`, and `promscale--0.0.0.sql`.
  - Update the versions of `incremental/001-extension.sql` in `incremental_freeze_test`
  - Update `upgradeable_from` in templates/promscale.control to add the previously released version
- [ ] Bump the version in Promscale's `EXTENSION_VERSION` (Renovate should automatically create a PR for this).
- [ ] Add the new version to `timescaledb/timescaledb-docker-ha` docker image.
<details>
<summary>Example</summary>
Once CI has generated the packages files, create a PR to update the HA image.
1. [This PR](https://github.com/timescale/timescaledb-docker-ha/pull/285/files) adds the necessary changes and CHANGELOG entry and wait for the CI to complete and request review from the Cloud team
2. [This PR](https://github.com/timescale/timescaledb-docker-ha/pull/286/files) actually stamps the version. Merge it with master and push the correct tag to trigger CI (see instructions in the repo)
</details>
