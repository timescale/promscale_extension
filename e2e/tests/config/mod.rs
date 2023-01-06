//! This file contains fixed docker container versions for the upgrade tests which
//! must be bumped every time that we release a new version of the extension.
pub(crate) const ALPINE_WITH_EXTENSION_LAST_RELEASED_PREFIX: &str =
    "timescaledev/promscale-extension:0.8.0-ts2.9.1-pg";
// TODO as soon as PG15 image is ready upstream
//pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG15: &str =
//    "TODO";
pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG14: &str =
    "timescale/timescaledb-ha:pg14.6-ts2.9.1-p1";
pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG13: &str =
    "timescale/timescaledb-ha:pg13.9-ts2.9.1-p1";
pub(crate) const HA_WITH_LAST_RELEASED_EXTENSION_PG12: &str =
    "timescale/timescaledb-ha:pg12.13-ts2.9.1-p1";
