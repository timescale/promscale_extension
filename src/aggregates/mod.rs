use crate::aggregates::gapfill_delta::_prom_ext::GapfillDeltaTransition;

mod counter;
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
