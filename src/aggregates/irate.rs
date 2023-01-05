use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::Internal;
    use pgx::*;

    use crate::aggregate_utils::in_aggregate_context;
    use crate::aggregates::{STALE_NAN, USECS_PER_SEC};
    use crate::palloc::{Inner, InternalAsValue, ToInternal};
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize, PostgresType, Debug)]
    #[pgx(sql = false)]
    pub struct IRateState {
        prior: Option<(i64, f64)>,
        last: Option<(i64, f64)>,
    }

    impl IRateState {
        pub fn new() -> Self {
            IRateState {
                prior: Option::None,
                last: Option::None,
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn irate_transition(
        state: Internal,
        sample_time: TimestampWithTimeZone,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Internal {
        irate_transition_inner(
            unsafe { state.to_inner() },
            sample_time.into(),
            sample_value,
            fc,
        )
        .internal()
    }

    #[allow(clippy::too_many_arguments)]
    fn irate_transition_inner(
        state: Option<Inner<IRateState>>,
        sample_time: i64,
        sample_value: f64,
        fc: pg_sys::FunctionCallInfo,
    ) -> Option<Inner<IRateState>> {
        unsafe {
            in_aggregate_context(fc, || {
                let mut state = state.unwrap_or_else(|| {
                    let state: Inner<_> = IRateState::new().into();
                    state
                });

                if sample_value.to_bits() == STALE_NAN {
                    return Some(state);
                };

                if let Some(last) = state.last {
                    if sample_time < last.0 {
                        error!("inputs are not in chronological order")
                    }
                }

                state.prior = state.last;
                state.last = Some((sample_time, sample_value));

                Some(state)
            })
        }
    }

    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn irate_final(state: Internal) -> Option<f64> {
        irate_final_inner(unsafe { state.to_inner() })
    }

    pub fn irate_final_inner(state: Option<Inner<IRateState>>) -> Option<f64> {
        if state.is_none() {
            return Some(0.0);
        }
        let state = state.unwrap();
        if state.prior.is_none() || state.last.is_none() {
            return Some(0.0);
        }
        let prior = state.prior.unwrap();
        let last = state.last.unwrap();
        let mut one = prior.1;
        let mut two = last.1;
        if two < one {
            // if the last sample was a counter reset just swap the values
            (one, two) = (two, one);
        }
        let secs = (last.0 - prior.0) as f64 / USECS_PER_SEC as f64;
        let delta = two - one;
        Some(delta / secs)
    }

    extension_sql!(
        r#"
    CREATE OR REPLACE AGGREGATE _prom_ext.irate(
        sample_time TIMESTAMPTZ,
        sample_value DOUBLE PRECISION)
    (
        sfunc=_prom_ext.irate_transition,
        stype=internal,
        finalfunc=_prom_ext.irate_final
    );
    "#,
        name = "create_irate",
        requires = [irate_transition, irate_final]
    );
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE ir_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO ir_test_table (t, v) VALUES
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
    fn test_irate_sum_1() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.irate(t, v order by t)
            FROM ir_test_table
            WHERE t < '2000-01-02T15:05:00+00:00'
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, 0.0_f64);
    }

    #[pg_test]
    fn test_irate_sum_2() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.irate(t, v order by t)
            FROM ir_test_table
            WHERE t < '2000-01-02T15:10:00+00:00'
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, 12_f64 / (5.0 * 60.0));
    }

    #[pg_test]
    fn test_irate_sum_3() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.irate(t, v order by t)
            FROM ir_test_table
            WHERE t < '2000-01-02T15:20:00+00:00'
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, (24_f64 - 15.0) / (5.0 * 60.0));
    }

    #[pg_test]
    fn test_irate_sum_4() {
        setup();
        let result = Spi::get_one::<f64>(
            r#"
            SELECT _prom_ext.irate(t, v order by t)
            FROM ir_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, 47_f64 / (5.0 * 60.0));
    }
}
