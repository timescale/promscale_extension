use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::error;
    use pgx::Internal;
    use pgx::*;

    use crate::aggregate_utils::in_aggregate_context;
    use crate::aggregates::{GapfillDeltaTransition, Milliseconds};
    use crate::palloc::{Inner, InternalAsValue, ToInternal};

    #[allow(clippy::too_many_arguments)]
    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn counter_transition(
        state: Internal,
        lowest_time: TimestampWithTimeZone,
        greatest_time: TimestampWithTimeZone,
        step_size: Milliseconds,
        range: Milliseconds, // the size of a window to calculate over
        sample_time: TimestampWithTimeZone,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Internal {
        counter_transition_inner(
            unsafe { state.to_inner() },
            lowest_time.into(),
            greatest_time.into(),
            step_size,
            range,
            sample_time.into(),
            sample_value,
            fc,
        )
        .internal()
    }

    #[allow(clippy::too_many_arguments)]
    fn counter_transition_inner(
        state: Option<Inner<GapfillDeltaTransition>>,
        lowest_time: i64,
        greatest_time: i64,
        step_size: Milliseconds,
        range: Milliseconds, // the size of a window to calculate over
        sample_time: i64,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Option<Inner<GapfillDeltaTransition>> {
        unsafe {
            in_aggregate_context(fc, || {
                if sample_time < lowest_time || sample_time > greatest_time {
                    error!(
                        "input time {} not in bounds [{}, {}]",
                        sample_time, lowest_time, greatest_time
                    )
                }

                let mut state = state.unwrap_or_else(|| {
                    let state: Inner<_> = GapfillDeltaTransition::new(
                        lowest_time,
                        greatest_time,
                        range,
                        step_size,
                        true,
                        true,
                    )
                    .into();
                    state
                });

                state.add_data_point(sample_time, sample_value);

                Some(state)
            })
        }
    }

    /// Backwards compatibility
    #[no_mangle]
    pub extern "C" fn pg_finfo_counter_rate_transition() -> &'static pg_sys::Pg_finfo_record {
        const V1_API: pg_sys::Pg_finfo_record = pg_sys::Pg_finfo_record { api_version: 1 };
        &V1_API
    }

    #[no_mangle]
    unsafe extern "C" fn counter_rate_transition(
        fcinfo: pg_sys::FunctionCallInfo,
    ) -> pg_sys::Datum {
        counter_transition_wrapper(fcinfo)
    }

    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn counter_extrapolate_final(state: Internal) -> Option<Vec<Option<f64>>> {
        counter_extrapolate_final_inner(unsafe { state.to_inner() })
    }

    pub fn counter_extrapolate_final_inner(
        state: Option<Inner<GapfillDeltaTransition>>,
    ) -> Option<Vec<Option<f64>>> {
        state.map(|mut s| s.as_vec())
    }

    extension_sql!(
        r#"
    CREATE OR REPLACE AGGREGATE _prom_ext.counter(
        lowest_time TIMESTAMPTZ,
        greatest_time TIMESTAMPTZ,
        step_size BIGINT,
        range BIGINT,
        sample_time TIMESTAMPTZ,
        sample_value DOUBLE PRECISION)
    (
        sfunc=_prom_ext.counter_transition,
        stype=internal,
        finalfunc=_prom_ext.counter_extrapolate_final
    );
    "#,
        name = "create_counter_aggregate",
        requires = [counter_transition, counter_extrapolate_final]
    );
}
