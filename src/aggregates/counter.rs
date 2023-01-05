use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::Internal;
    use pgx::*;

    use crate::aggregate_utils::in_aggregate_context;
    use crate::aggregates::STALE_NAN;
    use crate::palloc::{Inner, InternalAsValue, ToInternal};
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize, PostgresType, Debug)]
    #[pgx(sql = false)]
    pub struct CounterResetState {
        prior: (i64, f64),
        resets: i64,
        reset_sum: f64,
    }

    impl CounterResetState {
        pub fn new(t: i64, v: f64) -> Self {
            CounterResetState {
                prior: (t, v),
                resets: 0,
                reset_sum: 0.0,
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn counter_reset_transition(
        state: Internal,
        sample_time: TimestampWithTimeZone,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Internal {
        counter_reset_transition_inner(
            unsafe { state.to_inner() },
            sample_time.into(),
            sample_value,
            fc,
        )
        .internal()
    }

    #[allow(clippy::too_many_arguments)]
    fn counter_reset_transition_inner(
        state: Option<Inner<CounterResetState>>,
        sample_time: i64,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Option<Inner<CounterResetState>> {
        unsafe {
            in_aggregate_context(fc, || {
                let mut state = state.unwrap_or_else(|| {
                    let state: Inner<_> = CounterResetState::new(sample_time, sample_value).into();
                    state
                });

                if sample_time < state.prior.0 {
                    error!("inputs are not in chronological order")
                }

                if sample_value.to_bits() == STALE_NAN {
                    return Some(state);
                };

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

    pub fn counter_reset_sum_final_inner(state: Option<Inner<CounterResetState>>) -> Option<f64> {
        state.map(|state| state.reset_sum)
    }

    extension_sql!(
        r#"
    CREATE OR REPLACE AGGREGATE _prom_ext.counter_reset_sum(
        sample_time TIMESTAMPTZ,
        sample_value DOUBLE PRECISION)
    (
        sfunc=_prom_ext.counter_reset_transition,
        stype=internal,
        finalfunc=_prom_ext.counter_reset_sum_final
    );
    "#,
        name = "create_counter_reset_sum",
        requires = [counter_reset_transition, counter_reset_sum_final]
    );

    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn counter_reset_count_final(state: Internal) -> Option<i64> {
        counter_reset_count_final_inner(unsafe { state.to_inner() })
    }

    pub fn counter_reset_count_final_inner(state: Option<Inner<CounterResetState>>) -> Option<i64> {
        state.map(|state| state.resets)
    }

    extension_sql!(
        r#"
    CREATE OR REPLACE AGGREGATE _prom_ext.counter_reset_count(
        sample_time TIMESTAMPTZ,
        sample_value DOUBLE PRECISION)
    (
        sfunc=_prom_ext.counter_reset_transition,
        stype=internal,
        finalfunc=_prom_ext.counter_reset_count_final
    );
    "#,
        name = "create_counter_reset_count",
        requires = [counter_reset_transition, counter_reset_count_final]
    );
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE cr_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO cr_test_table (t, v) VALUES
                ('2000-01-02T15:00:00+00:00',0),
                ('2000-01-02T15:05:00+00:00',12),
                ('2000-01-02T15:10:00+00:00',24),
                ('2000-01-02T15:15:00+00:00',15),
                ('2000-01-02T15:20:00+00:00',48),
                ('2000-01-02T15:25:00+00:00',60),
                ('2000-01-02T15:30:00+00:00',0),
                ('2000-01-02T15:35:00+00:00',12),
                ('2000-01-02T15:40:00+00:00',24),
                ('2000-01-02T15:45:00+00:00',1),
                ('2000-01-02T15:50:00+00:00',48);
        "#,
        );
    }
    
    #[pg_test]
    fn test_counter_reset_sum_1() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.counter_reset_sum(t, v order by t)
            FROM cr_test_table
            WHERE t < '2000-01-02T15:05:00+00:00'
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 0_f64);
    }

    #[pg_test]
    fn test_counter_reset_sum_2() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.counter_reset_sum(t, v order by t)
            FROM cr_test_table
            WHERE t < '2000-01-02T15:20:00+00:00'
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 24_f64);
    }
    
    #[pg_test]
    fn test_counter_reset_sum_3() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.counter_reset_sum(t, v order by t)
            FROM cr_test_table
            WHERE t < '2000-01-02T15:40:00+00:00'
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 84_f64);
    }
    
    #[pg_test]
    fn test_counter_reset_sum_4() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.counter_reset_sum(t, v order by t)
            FROM cr_test_table
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 108_f64);
    }

    #[pg_test]
    fn test_counter_reset_count_1() {
        setup();
        let result = Spi::get_one::<i64>(
            r#"
            SELECT _prom_ext.counter_reset_count(t, v order by t)
            FROM cr_test_table
            WHERE t < '2000-01-02T15:05:00+00:00'
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 0_i64);
    }

    #[pg_test]
    fn test_counter_reset_count_2() {
        setup();
        let result = Spi::get_one::<i64>(
            r#"
            SELECT _prom_ext.counter_reset_count(t, v order by t)
            FROM cr_test_table
            WHERE t < '2000-01-02T15:20:00+00:00'
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 1_i64);
    }

    #[pg_test]
    fn test_counter_reset_count_3() {
        setup();
        let result = Spi::get_one::<i64>(
            r#"
            SELECT _prom_ext.counter_reset_count(t, v order by t)
            FROM cr_test_table
            WHERE t < '2000-01-02T15:40:00+00:00'
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 2_i64);
    }

    #[pg_test]
    fn test_counter_reset_count_4() {
        setup();
        let result = Spi::get_one::<i64>(
            r#"
            SELECT _prom_ext.counter_reset_count(t, v order by t)
            FROM cr_test_table
            ;"#,
        )
            .expect("SQL query failed");
        assert_eq!(result, 3_i64);
    }
}
