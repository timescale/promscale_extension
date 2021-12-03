use pgx::error;
use pgx::Internal;
use pgx::*;

use crate::aggregate_utils::in_aggregate_context;
use crate::aggregates::{GapfillDeltaTransition, Milliseconds};
use crate::palloc::{Inner, InternalAsValue, ToInternal};
use crate::raw::TimestampTz;

#[allow(clippy::too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn prom_rate_transition(
    state: Internal,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds,
    range: Milliseconds, // the size of a window to calculate over
    sample_time: TimestampTz,
    sample_value: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Internal {
    prom_rate_transition_inner(
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
fn prom_rate_transition_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
    lowest_time: pg_sys::TimestampTz,
    greatest_time: pg_sys::TimestampTz,
    step_size: Milliseconds,
    range: Milliseconds, // the size of a window to calculate over
    sample_time: pg_sys::TimestampTz,
    sample_value: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Option<Inner<GapfillDeltaTransition>> {
    unsafe {
        in_aggregate_context(fc, || {
            if sample_time < lowest_time || sample_time > greatest_time {
                error!(format!(
                    "input time {} not in bounds [{}, {}]",
                    sample_time, lowest_time, greatest_time
                ))
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

// implementation of prometheus rate function
// for proper behavior the input must be ORDER BY sample_time
extension_sql!(
    r#"
CREATE AGGREGATE @extschema@.prom_rate(
    lowest_time TIMESTAMPTZ,
    greatest_time TIMESTAMPTZ,
    step_size BIGINT,
    range BIGINT,
    sample_time TIMESTAMPTZ,
    sample_value DOUBLE PRECISION)
(
    sfunc=@extschema@.prom_rate_transition,
    stype=internal,
    finalfunc=@extschema@.prom_extrapolate_final
);
"#,
    name = "create_prom_rate_aggregate",
    requires = [prom_rate_transition, prom_extrapolate_final]
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE gfi_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfi_test_table (t, v) VALUES
                ('2000-01-02T15:00:00+00:00',0),
                ('2000-01-02T15:05:00+00:00',12),
                ('2000-01-02T15:10:00+00:00',24),
                ('2000-01-02T15:15:00+00:00',36),
                ('2000-01-02T15:20:00+00:00',48),
                ('2000-01-02T15:25:00+00:00',60),
                ('2000-01-02T15:30:00+00:00',0),
                ('2000-01-02T15:35:00+00:00',12),
                ('2000-01-02T15:40:00+00:00',24),
                ('2000-01-02T15:45:00+00:00',36),
                ('2000-01-02T15:50:00+00:00',48);
        "#,
        );
    }

    #[pg_test]
    fn test_prom_rate_no_reset_in_range() {
        setup();
        let result = Spi::get_one::<Vec<f64>>(
            r#"
            SELECT
                prom_rate(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:25:00+00:00'::TIMESTAMPTZ
                , 25 * 60 * 1000
                , 25 * 60 * 1000
                , t
                , v order by t)
            FROM gfi_test_table
            WHERE t <= '2000-01-02T15:25:00+00:00'::TIMESTAMPTZ
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, vec![0.04_f64]);
    }

    #[pg_test]
    fn test_prom_rate_reset_in_range() {
        setup();
        let result = Spi::get_one::<Vec<f64>>(
            r#"
            SELECT
                prom_rate(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ
                , 50 * 60 * 1000
                , 50 * 60 * 1000
                , t
                , v order by t)
            FROM gfi_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, vec![0.036_f64]);
    }

    #[pg_test]
    fn test_prom_rate_extrapolate() {
        setup();
        let result = Spi::get_one::<Vec<f64>>(
            r#"
            SELECT
                prom_rate(
                  '2000-01-02T14:55:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:55:00+00:00'::TIMESTAMPTZ
                , 60 * 60 * 1000
                , 60 * 60 * 1000
                , t
                , v order by t)
            FROM gfi_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, vec![0.033_f64]);
    }
}
