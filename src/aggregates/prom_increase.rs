use pgx::error;
use pgx::Internal;
use pgx::*;

use crate::aggregate_utils::in_aggregate_context;
use crate::aggregates::Milliseconds;
use crate::palloc::{Inner, InternalAsValue, ToInternal};
use crate::raw::TimestampTz;
use crate::GapfillDeltaTransition;

#[allow(clippy:too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn prom_increase_transition(
    state: Internal,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds, // `prev_now - step` is where the next window starts
    range: Milliseconds,     // the size of a window to delta over
    time: TimestampTz,
    val: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Internal {
    prom_increase_transition_inner(
        unsafe { state.to_inner() },
        lowest_time.into(),
        greatest_time.into(),
        step_size,
        range,
        time.into(),
        val,
        fc,
    )
    .internal()
}
pub fn prom_increase_transition_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
    lowest_time: pg_sys::TimestampTz,
    greatest_time: pg_sys::TimestampTz,
    step_size: Milliseconds, // `prev_now - step` is where the next window starts
    range: Milliseconds,     // the size of a window to delta over
    time: pg_sys::TimestampTz,
    val: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Option<Inner<GapfillDeltaTransition>> {
    unsafe {
        in_aggregate_context(fc, || {
            if time < lowest_time || time > greatest_time {
                error!("input time less than lowest time")
            }

            let mut state = state.unwrap_or_else(|| {
                let state: Inner<_> = GapfillDeltaTransition::new(
                    lowest_time,
                    greatest_time,
                    range,
                    step_size,
                    true,
                    false,
                )
                .into();
                state
            });

            state.add_data_point(time, val);

            Some(state)
        })
    }
}

// implementation of prometheus increase function
// for proper behavior the input must be ORDER BY sample_time
extension_sql!(
    r#"
CREATE AGGREGATE @extschema@.prom_increase(
    lowest_time TIMESTAMPTZ,
    greatest_time TIMESTAMPTZ,
    step BIGINT,
    range BIGINT,
    sample_time TIMESTAMPTZ,
    sample_value DOUBLE PRECISION)
(
    sfunc=@extschema@.prom_increase_transition,
    stype=internal,
    finalfunc=@extschema@.prom_delta_final
);
"#,
    name = "create_prom_increase_aggregate"
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;

    #[pg_test]
    fn test_prom_increase_basic_50m() {
        Spi::run(
            r#"
            CREATE TABLE gfi_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfi_test_table (t, v) VALUES
                ('2000-01-02T15:00:00+00:00',0),
                ('2000-01-02T15:05:00+00:00',10),
                ('2000-01-02T15:10:00+00:00',20),
                ('2000-01-02T15:15:00+00:00',30),
                ('2000-01-02T15:20:00+00:00',40),
                ('2000-01-02T15:25:00+00:00',50),
                ('2000-01-02T15:30:00+00:00',60),
                ('2000-01-02T15:35:00+00:00',70),
                ('2000-01-02T15:40:00+00:00',80),
                ('2000-01-02T15:45:00+00:00',90),
                ('2000-01-02T15:50:00+00:00',100);
        "#);

        let result = Spi::get_one::<Vec<f64>>(
            "SELECT prom_increase('2000-01-02T15:00:00+00:00'::TIMESTAMPTZ, '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ, 50 * 60 * 1000, 50 * 60 * 1000, t, v order by t) FROM gfi_test_table"
        ).expect("SQL guery failed");
        assert_eq!(result, vec![100_f64]);
    }

    #[pg_test]
    fn test_prom_increase_basic_reset_zero() {
        Spi::run(
            r#"
            CREATE TABLE gfi_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfi_test_table (t, v) VALUES
                ('2000-01-02T15:00:00+00:00',0),
                ('2000-01-02T15:05:00+00:00',10),
                ('2000-01-02T15:10:00+00:00',20),
                ('2000-01-02T15:15:00+00:00',30),
                ('2000-01-02T15:20:00+00:00',40),
                ('2000-01-02T15:25:00+00:00',50),
                ('2000-01-02T15:30:00+00:00',0),
                ('2000-01-02T15:35:00+00:00',10),
                ('2000-01-02T15:40:00+00:00',20),
                ('2000-01-02T15:45:00+00:00',30),
                ('2000-01-02T15:50:00+00:00',40);
        "#);

        let result = Spi::get_one::<Vec<f64>>(
            "SELECT prom_increase('2000-01-02T15:00:00+00:00'::TIMESTAMPTZ, '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ, 50 * 60 * 1000, 50 * 60 * 1000, t, v order by t) FROM gfi_test_table;"
        ).expect("SQL query failed");
        assert_eq!(result, vec![90_f64]);
    }

    #[pg_test]
    fn test_prom_increase_counter_reset_nonzero() {
        Spi::run(
            r#"
            CREATE TABLE gfi_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfi_test_table (t, v) VALUES
                ('2000-01-02T15:00:00+00:00',0),
                ('2000-01-02T15:05:00+00:00',1),
                ('2000-01-02T15:10:00+00:00',2),
                ('2000-01-02T15:15:00+00:00',3),
                ('2000-01-02T15:20:00+00:00',2),
                ('2000-01-02T15:25:00+00:00',3),
                ('2000-01-02T15:30:00+00:00',4);
        "#);
        let result =
            Spi::get_one::<Vec<f64>>(
            "SELECT prom_increase('2000-01-02T15:00:00+00:00'::TIMESTAMPTZ, '2000-01-02T15:30:00+00:00'::TIMESTAMPTZ, 30 * 60 * 1000, 30 * 60 * 1000, t, v order by t) FROM gfi_test_table;"
            ).expect("SQL select failed");
        assert_eq!(result, vec![7_f64]);
    }
}
