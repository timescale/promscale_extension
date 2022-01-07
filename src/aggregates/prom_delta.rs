use pgx::*;

use pgx::error;

use crate::aggregates::{GapfillDeltaTransition, Milliseconds};

#[allow(non_camel_case_types)]
pub struct prom_delta;

// prom divides time into sliding windows of fixed size, e.g.
// |  5 seconds  |  5 seconds  |  5 seconds  |  5 seconds  |  5 seconds  |
// we take the first and last values in that bucket and uses `last-first` as the
// value for that bucket.
//  | a b c d e | f g h i | j   k |   m    |
//  |   e - a   |  i - f  | k - j | <null> |
#[pg_aggregate]
impl Aggregate for prom_delta {
    type State = Option<GapfillDeltaTransition>;
    type Args = (
        name!(lowest_time, pg_sys::TimestampTz),
        name!(greatest_time, pg_sys::TimestampTz),
        name!(step_size, Milliseconds),
        name!(range, Milliseconds),
        name!(sample_time, pg_sys::TimestampTz),
        name!(sample_value, f64),
    );
    type Finalize = Option<Vec<Option<f64>>>;

    fn state(
        state: Self::State,
        (lowest_time, greatest_time, step_size, range, sample_time, sample_value): Self::Args,
        _: pg_sys::FunctionCallInfo,
    ) -> Self::State {
        if sample_time < lowest_time || sample_time > greatest_time {
            error!(format!(
                "input time {} not in bounds [{}, {}]",
                sample_time, lowest_time, greatest_time
            ))
        }

        let mut state = state.unwrap_or_else(|| {
            GapfillDeltaTransition::new(lowest_time, greatest_time, range, step_size, false, false)
        });

        state.add_data_point(sample_time, sample_value);

        Some(state)
    }

    fn finalize(
        current: Self::State,
        _: Self::OrderedSetArgs,
        _: pg_sys::FunctionCallInfo,
    ) -> Self::Finalize {
        current.map(|mut s| s.as_vec())
    }
}

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

    #[pg_test(error = "input time 631292400000000 not in bounds [140400000000, 143100000000]")]
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
