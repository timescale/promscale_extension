use pgx::*;

use pgx::error;

use crate::aggregate_utils::in_aggregate_context;
use crate::aggregates::{GapfillDeltaTransition, Milliseconds};
use crate::palloc::{Inner, InternalAsValue, ToInternal};
use crate::raw::TimestampTz;

// prom divides time into sliding windows of fixed size, e.g.
// |  5 seconds  |  5 seconds  |  5 seconds  |  5 seconds  |  5 seconds  |
// we take the first and last values in that bucket and uses `last-first` as the
// value for that bucket.
//  | a b c d e | f g h i | j   k |   m    |
//  |   e - a   |  i - f  | k - j | <null> |
#[allow(clippy::too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn prom_delta_transition(
    state: Internal,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds, // `prev_now - step_size` is where the next window starts
    range: Milliseconds,     // the size of a window to delta over
    sample_time: TimestampTz,
    sample_value: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Internal {
    prom_delta_transition_inner(
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
fn prom_delta_transition_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
    lowest_time: pg_sys::TimestampTz,
    greatest_time: pg_sys::TimestampTz,
    step_size: Milliseconds, // `prev_now - step` is where the next window starts
    range: Milliseconds,     // the size of a window to delta over
    sample_time: pg_sys::TimestampTz,
    sample_value: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Option<Inner<GapfillDeltaTransition>> {
    unsafe {
        in_aggregate_context(fc, || {
            if sample_time < lowest_time || sample_time > greatest_time {
                error!("input time less than lowest time")
            }

            let mut state = state.unwrap_or_else(|| {
                let state: Inner<_> = GapfillDeltaTransition::new(
                    lowest_time,
                    greatest_time,
                    range,
                    step_size,
                    false,
                    false,
                )
                .into();
                state
            });

            state.add_data_point(sample_time, sample_value);

            Some(state)
        })
    }
}

// implementation of prometheus delta function
// for proper behavior the input must be ORDER BY sample_time
extension_sql!(
    r#"
CREATE AGGREGATE @extschema@.prom_delta(
    lowest_time TIMESTAMPTZ,
    greatest_time TIMESTAMPTZ,
    step_size BIGINT,
    range BIGINT,
    sample_time TIMESTAMPTZ,
    sample_value DOUBLE PRECISION)
(
    sfunc=@extschema@.prom_delta_transition,
    stype=internal,
    finalfunc=@extschema@.prom_extrapolate_final
);
"#,
    name = "create_prom_delta_aggregate",
    requires = [prom_delta_transition, prom_extrapolate_final]
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE gfd_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfd_test_table (t, v) VALUES
                ('2000-01-02 15:00:00 UTC', 0),
                ('2000-01-02 15:05:00 UTC', 50),
                ('2000-01-02 15:10:00 UTC', 100),
                ('2000-01-02 15:15:00 UTC', 150),
                ('2000-01-02 15:20:00 UTC', 200),
                ('2000-01-02 15:25:00 UTC', 200),
                ('2000-01-02 15:30:00 UTC', 150),
                ('2000-01-02 15:35:00 UTC', 100),
                ('2000-01-02 15:40:00 UTC', 50),
                ('2000-01-02 15:45:00 UTC', 0);
            "#,
        );
    }

    fn prepare_query(start: &str, sample_time: &str) -> String {
        format!(
            r#"
            SELECT
                prom_delta(
                    {}::TIMESTAMPTZ
                  , '2000-01-02 15:45:00 UTC'::TIMESTAMPTZ
                  , 20 * 60 * 1000
                  , 20 * 60 * 1000
                  , {}::TIMESTAMPTZ
                  , v order by t)
            FROM gfd_test_table;"#,
            start, sample_time
        )
    }

    #[pg_test(error = "sample_time is null")]
    fn test_prom_delta_with_null_time_fails() {
        setup();
        Spi::get_one::<Vec<f64>>(&*prepare_query("'2000-01-02 15:00:00 UTC'", "NULL"));
    }

    #[pg_test(error = "input time less than lowest time")]
    fn test_prom_delta_with_input_time_less_than_lowest_time_fails() {
        setup();
        Spi::get_one::<Vec<f64>>(&*prepare_query(
            "'2000-01-02 15:00:00 UTC'",
            "'2020-01-02 15:00:00 UTC'",
        ));
    }

    #[pg_test]
    fn test_prom_delta_success() {
        setup();
        let retval = Spi::get_one::<Vec<f64>>(&*prepare_query("'2000-01-02 15:00:00 UTC'", "t"))
            .expect("SQL select failed");
        assert_eq!(retval, vec![200_f64, -150_f64]);
    }

    #[pg_test]
    fn test_prom_delta_success_two() {
        setup();
        let retval =
            Spi::get_one::<Vec<Option<f64>>>(&*prepare_query("'2000-01-02 14:15:00 UTC'", "t"))
                .expect("SQL select failed");
        assert_eq!(retval, vec![None, None, Some(200_f64), Some(-50_f64)]);
    }
}
