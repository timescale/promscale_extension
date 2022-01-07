use pgx::error;
use pgx::*;

use crate::aggregates::{GapfillDeltaTransition, Milliseconds};

#[allow(non_camel_case_types)]
pub struct prom_rate;

#[pg_aggregate]
impl Aggregate for prom_rate {
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
            GapfillDeltaTransition::new(lowest_time, greatest_time, range, step_size, true, true)
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
