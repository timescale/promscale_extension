# Changelog
All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

We use the following categories for changes:
- `Added` for new features.
- `Changed` for changes in existing functionality.
- `Deprecated` for soon-to-be removed features.
- `Removed` for now removed features.
- `Fixed` for any bug fixes.
- `Security` in case of vulnerabilities.

## [Unreleased]

### Fixed

- Correctly identify and drop `prom_schema_migrations` [#372]
- Use `cluster` label from `_prom_catalog.label` to report about HA setup [#398]
- Optimize `promscale_sql_telemetry()` by removing `metric_bytes_total` and `traces_spans_bytes_total` metrics [#388]

## [0.5.2] - 2021-06-20

### Changed

- Correct storage type for attributes deriving from `tag_map` and `tag_v` [#365]

### Fixed

- Fix permissions set in `make install` [#355]

## [0.5.1] - 2021-06-08

### Added

- Added public API to get metric retention period [#331]

### Changed

- Stop all background workers for the duration of the upgrade [#290]

### Fixed

- Use `TEXT` instead of `NAME` for function args [#310]
- Fix storage type for `tag_map` and `tag_v` types [#314]
- Drop old versions of func/proc where signature changed [#323]
- Remove some code paths for deprecated versions [#326]
- Fix upgrade path from 0.5.0 to 0.5.1 [#347]

## [0.3.0] - 2021-12-01

No release notes available.
