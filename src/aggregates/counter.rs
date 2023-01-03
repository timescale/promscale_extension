use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::Internal;
    use pgx::*;

    use crate::aggregate_utils::in_aggregate_context;
    use crate::palloc::{Inner, InternalAsValue, ToInternal};
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize, PostgresType, Debug)]
    #[pgx(sql = false)]
    pub struct RateState {
        first: (i64, f64),
        prior: (i64, f64),
        resets: i64,
        reset_sum: f64,
    }

    impl RateState {
        pub fn new(t: i64, v: f64) -> Self {
            RateState {
                first: (t, v),
                prior: (t, v),
                resets: 0,
                reset_sum: 0.0,
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn rate_transition(
        state: Internal,
        sample_time: TimestampWithTimeZone,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Internal {
        rate_transition_inner(
            unsafe { state.to_inner() },
            sample_time.into(),
            sample_value,
            fc,
        )
        .internal()
    }

    #[allow(clippy::too_many_arguments)]
    fn rate_transition_inner(
        state: Option<Inner<RateState>>,
        sample_time: i64,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Option<Inner<RateState>> {
        unsafe {
            in_aggregate_context(fc, || {
                let mut state = state.unwrap_or_else(|| {
                    let state: Inner<_> = RateState::new(sample_time, sample_value).into();
                    state
                });

                if sample_value < state.prior.1 {
                    state.resets += 1;
                    state.reset_sum += state.prior.1;
                }

                state.prior = (sample_time, sample_value);

                Some(state)
            })
        }
    }

    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn counter_reset_sum_final(state: Internal) -> Option<f64> {
        counter_reset_sum_final_inner(unsafe { state.to_inner() })
    }

    pub fn counter_reset_sum_final_inner(state: Option<Inner<RateState>>) -> Option<f64> {
        state.map(|state| state.reset_sum)
    }

    extension_sql!(
        r#"
    CREATE OR REPLACE AGGREGATE _prom_ext.counter_reset_sum(
        sample_time TIMESTAMPTZ,
        sample_value DOUBLE PRECISION)
    (
        sfunc=_prom_ext.rate_transition,
        stype=internal,
        finalfunc=_prom_ext.counter_reset_sum_final
    );
    "#,
        name = "create_counter_reset_sum",
        requires = [rate_transition, counter_reset_sum_final]
    );
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE crs_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO crs_test_table (t, v) VALUES
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
    fn test_counter_reset_sum_all() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.counter_reset_sum(t, v order by t)
            FROM crs_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, 60_f64);
    }
}
