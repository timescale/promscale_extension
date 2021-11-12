use pgx::*;
use pgx::Internal;
use crate::GapfillDeltaTransition;
use crate::palloc::{Inner, InternalAsValue};

mod prom_delta;
mod prom_increase;

pub type Milliseconds = i64;

#[pg_extern()]
pub fn prom_delta_final(state: Internal) -> Option<Vec<Option<f64>>> {
    prom_delta_final_inner(unsafe { state.to_inner() })
}
pub fn prom_delta_final_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
) -> Option<Vec<Option<f64>>> {
    state.map(|mut s| s.to_vec())
}
