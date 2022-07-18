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

## [0.5.4] - 2022-07-18

Due to critical bug with extension upgrade to 0.5.3, we're skipping version 0.5.3 and incorporating the fix into 0.5.4. If you have installed 0.5.3 fresh you should have no isssue upgrading to 0.5.4. Upgrade paths to 0.5.3 are thus being removed. Images holding Promscale Extension 0.5.3 were purged from sources we have countrol over and we strongly advice anyone who managed to create such images to purge them for good.
With this release we've also made sure to improve our test suite to prevent such issues from happenning in the future.

## [0.5.3] - 2022-07-14

### Added

- Configure `epoch_duration` for Promscale series cache via `_prom_catalog.default` [#396]
- Support for RE2-based regex used in Prometheus for PromQL via `_prom_ext.re2_match(text, text)` function [#362]
- Various improvements for development cycle

### Fixed

- Correctly identify and drop `prom_schema_migrations` [#372]
- Support cargo 1.62.0 pkgid format [#390]
- Use `cluster` label from `_prom_catalog.label` to report about HA setup [#398]
- Optimize `promscale_sql_telemetry()` by removing `metric_bytes_total` and `traces_spans_bytes_total` metrics [#388]
- A minor bug in epoch_abort that caused a confusing message in RAISE [#417].

### Changed

- Drop support for Debian Stretch and Ubuntu Hirsute [#404]

## [0.5.2] - 2022-06-20

### Changed

- Correct storage type for attributes deriving from `tag_map` and `tag_v` [#365]

### Fixed

- Fix permissions set in `make install` [#355]

## [0.5.1] - 2022-06-08

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
