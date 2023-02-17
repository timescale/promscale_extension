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

## [0.8.0 - 2023-01-05]

### Changed

- Maintenance jobs were separated from one another. The bejaviour of the old 
  `prom_api.config_maintenance_jobs` call changed and it sets identical parameters
  for each job type (e.g. parallism 2 means each job type has 2 jobs, not 2 jobs in total).
  There is also the new `prom_api.config_maintenance_jobs` that allows configuring
  them individually. Finally, the new default worker allocation is 2 metrics retention
  jobs, 3 jobs for metrics compression and 1 job for traces retention. [#555] [#588]
- Removed disk size related columns from `prom_info.metric`. 
  Added `prom_info.metric_detail` which includes the disk size related columns. 
  Improved the performance of these. [#547]
- The metric compression job now only locks metrics which are known to have chunks
  that need to be compressed [#576]
- Renamed `_ps_catalog.chunks_to_freeze` to `_ps_catalog.compressed_chunks_to_freeze` [#595]
- All docker images upgraded to use TimescaleDB 2.9 [#598]
- The extension is updated to add support PostgreSQL 15. [#590]

### Added
- Telemetry for active series and last updated [#534]
- Added `_ps_catalog.compressed_chunks_missing_stats` view [#595]

### Fixed
- Column conflict when creating a metric view with a label called `series`
  [#559]

## [0.7.0 - 2022-10-03]

### Added

- Added `_ps_catalog.chunks_to_vacuum_freeze` to identify compressed chunks
  containing tuples not yet frozen [#503] and [#509]
- Added three functions used for coordinating the vacuum engine
  `_prom_catalog.get_advisory_lock_id_vacuum_engine`,
  `_prom_catalog.lock_for_vacuum_engine`, and
  `_prom_catalog.unlock_for_vacuum_engine()` [#511]
- Added ability for database owners to override security checks in script migrating from Promscale < 0.10.0 [#524]

### Changed

- The timescaledb extension is now a mandatory prerequisite [#515].
- Reuse ingestion temp tables across batches [#526]

### Fixed

- Correctly remove all expired series [#521]
- Fix migration when a metric is not compressed [#505]

### Changed

- Drop non empty span name check constraint from `_ps_trace.operation` table [#520]

## [0.6.0] - 2022-08-25

### Added

- Added `prom_api.get_default_chunk_interval()` and `prom_api.get_metric_chunk_interval(TEXT)` [#464].
- Added `_ps_trace.text_matches()` and `_ps_trace.tag_v_text_eq_matching_tags()` [#461]

### Fixed

- Don't fail metric deletion if some tables or views are missing [#460]
- Incorrect type coercion when using `tag_map` with `=` operator [#462]
- During upgrade from 0.3.x only alter relations which actually exist [#474]

### Changed

- `ps_trace.delete_all_traces()` can only be executed when no Promscale connectors are running [#437].
- `_prom_catalog.create_series` now throws an exception if the label ids in label_array do not exist in the _prom_catalog.label table [#465].

## [0.5.4] - 2022-07-18

Due to a critical bug in upgrading to 0.5.3, we're skipping version 0.5.3 and
incorporating the fix into 0.5.4. We have removed the build artifacts for
Promscale Extension 0.5.3. We strongly advise anyone who used the 0.5.3 tag in
our GitHub or DockerHub repositories to delete these artifacts.

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
