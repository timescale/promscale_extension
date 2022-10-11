//! This file contains fixed docker container versions for the upgrade tests which
//! must be bumped every time that we release a new version of the extension.
pub(crate) const ALPINE_WITH_EXTENSION_LAST_RELEASED_PREFIX: &str =
    "timescaledev/promscale-extension:0.7.0-ts2.7.2-pg";
pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG14: &str =
    "timescale/timescaledb-ha:pg14.5-ts2.8.1-p1";
pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG13: &str =
    "timescale/timescaledb-ha:pg13.8-ts2.8.1-p1";
pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG12: &str =
    "timescale/timescaledb-ha:pg12.12-ts2.8.1-p1";
