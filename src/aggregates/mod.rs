use crate::aggregates::gapfill_delta::GapfillDeltaTransition;
use pgx::Internal;
use pgx::*;

use crate::palloc::{Inner, InternalAsValue};

mod gapfill_delta;
mod prom_delta;
mod prom_increase;
mod prom_rate;
mod vector_selector;

pub type Milliseconds = i64;
pub type Microseconds = i64;

pub const STALE_NAN: u64 = 0x7ff0000000000002;
pub const USECS_PER_SEC: i64 = 1_000_000;
pub const USECS_PER_MS: i64 = 1_000;

// TODO: Rename this function.
// It is used by multiple aggregates, not only `prom_delta`. Renaming it will
// break binary compatibility with old extension installs, so we need to figure
// that out first.
#[pg_extern()]
pub fn prom_delta_final(state: Internal) -> Option<Vec<Option<f64>>> {
    prom_delta_final_inner(unsafe { state.to_inner() })
}
pub fn prom_delta_final_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
) -> Option<Vec<Option<f64>>> {
    state.map(|mut s| s.to_vec())
}
