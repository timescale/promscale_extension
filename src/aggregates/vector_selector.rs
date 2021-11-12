use pgx::*;

use pgx::error;

use crate::aggregate_utils::in_aggregate_context;
use crate::aggregates::{Milliseconds, STALE_NAN, USECS_PER_MS};
use serde::{Deserialize, Serialize};

use crate::palloc::{Inner, InternalAsValue, ToInternal};
use crate::raw::{bytea, TimestampTz};

// a vector selector aggregate has the same semantics as parse.VectorSelector processing
// in Prometheus. Namely, for all timestamps ts in the series:
//     ts := ev.startTimestamp; ts <= ev.endTimestamp; ts += ev.interval
// we return the last sample.value such that the time sample.time <= ts and sample.time >= ts-lookback.
// if such a sample doesn't exist return NULL (None).
// thus, the vector selector returns a regular series of values corresponding to all the points in the
// ts series above.
// Note that for performance, this aggregate is parallel-izable, combinable, and does not expect ordered inputs.
#[allow(clippy:too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_transition(
    state: Internal,
    start_time: TimestampTz,
    end_time: TimestampTz,
    bucket_width: Milliseconds,
    lookback: Milliseconds,
    time: TimestampTz,
    value: f64,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Internal {
    vector_selector_transition_inner(
        unsafe { state.to_inner() },
        start_time.into(),
        end_time.into(),
        bucket_width,
        lookback,
        time.into(),
        value,
        fcinfo,
    )
    .internal()
}
pub fn vector_selector_transition_inner(
    state: Option<Inner<VectorSelector>>,
    start_time: pg_sys::TimestampTz,
    end_time: pg_sys::TimestampTz,
    bucket_width: Milliseconds,
    lookback: Milliseconds,
    time: pg_sys::TimestampTz,
    value: f64,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Option<Inner<VectorSelector>> {
    unsafe {
        in_aggregate_context(fcinfo, || {
            let mut state = state.unwrap_or_else(|| {
                let state: Inner<VectorSelector> =
                    VectorSelector::new(start_time, end_time, bucket_width, lookback).into();
                state
            });

            state.insert(time, value);

            Some(state)
        })
    }
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_final(
    state: Internal, /* Option<Inner<VectorSelector>> */
) -> Option<Vec<Option<f64>>> {
    let state: Option<Inner<VectorSelector>> = unsafe { state.to_inner() };
    state.map(|s| s.to_pg_array())
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_serialize(state: Internal) -> bytea {
    let state: &mut VectorSelector = unsafe { state.get_mut().unwrap() };
    crate::do_serialize!(state)
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_deserialize(bytes: bytea, _internal: Internal) -> Internal {
    let v: VectorSelector = crate::do_deserialize!(bytes, VectorSelector);
    Inner::from(v).internal()
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_combine(
    state1: Internal,
    state2: Internal,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Internal {
    vector_selector_combine_inner(
        unsafe { state1.to_inner() },
        unsafe { state2.to_inner() },
        fcinfo,
    )
    .internal()
}
pub fn vector_selector_combine_inner(
    state1: Option<Inner<VectorSelector>>,
    state2: Option<Inner<VectorSelector>>,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Option<Inner<VectorSelector>> {
    unsafe {
        in_aggregate_context(fcinfo, || {
            match (state1, state2) {
                (None, None) => None,
                (None, Some(state2)) => {
                    let s = state2.clone();
                    Some(s.into())
                }
                (Some(state1), None) => {
                    let s = state1.clone();
                    Some(s.into())
                } //should I make these return themselves?
                (Some(state1), Some(state2)) => {
                    let mut s1 = state1.clone(); // is there a way to avoid if it doesn't need it
                    s1.combine(&state2);
                    Some(s1.into())
                }
            }
        })
    }
}

extension_sql!(
    r#"
CREATE AGGREGATE @extschema@.vector_selector(
    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,
    bucket_width BIGINT,
    lookback BIGINT,
    sample_time TIMESTAMPTZ,
    sample_value DOUBLE PRECISION)
(
    sfunc = vector_selector_transition,
    stype = internal,
    finalfunc = vector_selector_final,
    combinefunc = vector_selector_combine,
    serialfunc = vector_selector_serialize,
    deserialfunc = vector_selector_deserialize,
    parallel = safe
);
"#,
    name = "create_vector_selector_aggregate"
);

// The internal state consists of a vector non-overlapping sample buckets. Each bucket
// has a corresponding (virtual) timestamp corresponding to the ts series
// described above. The timestamp represents the maximum value stored in the
// bucket (inclusive). The minimum value is defined by the maximum value of
// the previous bucket (exclusive).
// the value stored inside the bucket is the last sample in the bucket (sample with highest timestamp)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VectorSelector {
    first_bucket_max_time: pg_sys::TimestampTz,
    last_bucket_max_time: pg_sys::TimestampTz,
    end_time: pg_sys::TimestampTz, //only used for error checking
    bucket_width: Milliseconds,
    lookback: Milliseconds,
    elements: Vec<Option<(pg_sys::TimestampTz, f64)>>,
}

impl VectorSelector {
    pub fn new(
        start_time: pg_sys::TimestampTz,
        end_time: pg_sys::TimestampTz,
        bucket_width: Milliseconds,
        lookback: Milliseconds,
    ) -> Self {
        let num_buckets = ((end_time - start_time) / (bucket_width * USECS_PER_MS)) + 1;

        let last_bucket_max_time =
            end_time - ((end_time - start_time) % (bucket_width * USECS_PER_MS));

        VectorSelector {
            first_bucket_max_time: start_time,
            last_bucket_max_time: last_bucket_max_time,
            end_time: end_time,
            bucket_width: bucket_width,
            lookback: lookback,
            elements: vec![None; num_buckets as usize],
        }
    }

    fn combine(&mut self, other: &Inner<VectorSelector>) {
        if self.first_bucket_max_time != other.first_bucket_max_time
            || self.last_bucket_max_time != other.last_bucket_max_time
            || self.end_time != other.end_time
            || self.bucket_width != other.bucket_width
            || self.lookback != other.lookback
            || self.elements.len() != other.elements.len()
        {
            error!("trying to combine incomptible vector selectors")
        }

        for it in self.elements.iter_mut().zip(other.elements.iter()) {
            let (s, o) = it;
            match (*s, o) {
                (None, None) => (),
                (Some(_), None) => (),
                (None, Some(other)) => *s = Some(*other),
                (Some(mine), Some(other)) => {
                    let (my_t, _): (pg_sys::TimestampTz, f64) = mine;
                    let (other_t, _): (pg_sys::TimestampTz, f64) = *other;
                    if other_t > my_t {
                        *s = Some(*other)
                    }
                }
            }
        }
    }

    fn insert(&mut self, time: pg_sys::TimestampTz, val: f64) {
        if time > self.end_time {
            error!("input time greater than expected")
        }
        if time > self.last_bucket_max_time {
            return;
        }

        let bucket_idx = self.get_bucket(time);
        let contents = self.elements[bucket_idx];

        match contents {
            Some(x) => {
                let (exising_time, _) = x;
                if exising_time < time {
                    self.elements[bucket_idx] = Some((time, val))
                }
            }
            None => self.elements[bucket_idx] = Some((time, val)),
        }
    }

    fn get_bucket(&self, time: pg_sys::TimestampTz) -> usize {
        if time < self.first_bucket_max_time - (self.lookback * USECS_PER_MS) {
            error!("input time less than expected")
        }

        if time > self.last_bucket_max_time {
            error!("input time greater than the last bucket's time")
        }

        if time <= self.first_bucket_max_time {
            return 0;
        }

        let offset = time - self.first_bucket_max_time;
        let mut bucket = (offset / (self.bucket_width * USECS_PER_MS)) + 1;
        if offset % (self.bucket_width * USECS_PER_MS) == 0 {
            bucket -= 1
        }
        bucket as usize
    }

    pub fn results(&self) -> Vec<Option<f64>> {
        let mut vals: Vec<Option<f64>> = Vec::with_capacity(self.elements.capacity());

        //last value found in any bucket
        let mut last = None;

        /* staleNaN check happens after the bucket/last item is retrieved.
         * if the value is a staleNaN, then the result is a NULL
         * see vectorSelectorSingle in engine.go
         */

        let mut ts = self.first_bucket_max_time;
        for content in &self.elements {
            let mut pushed = false;
            match content {
                /* if current bucket is empty, last value may still apply */
                None => match last {
                    Some(tuple) => {
                        let (t, v): (pg_sys::TimestampTz, f64) = tuple;
                        if t >= ts - (self.lookback * USECS_PER_MS) && v.to_bits() != STALE_NAN {
                            pushed = true;
                            vals.push(Some(v));
                        }
                    }
                    None => (),
                },
                Some(tuple) => {
                    let (t, v2): &(pg_sys::TimestampTz, f64) = tuple;
                    //if buckets > lookback, timestamp in bucket may still be out of lookback
                    if *t >= ts - (self.lookback * USECS_PER_MS) && v2.to_bits() != STALE_NAN {
                        pushed = true;
                        vals.push(Some(*v2));
                    }
                    last = *content
                }
            }
            if !pushed {
                //push a null
                vals.push(None);
            }
            ts = ts + (self.bucket_width * USECS_PER_MS)
        }

        vals
    }

    pub fn to_pg_array(&self) -> Vec<Option<f64>> {
        self.results()
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE gfv_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfv_test_table (t, v) VALUES
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
        "#,
        );
    }

    #[pg_test]
    fn test_vector_selector() {
        setup();
        let result = Spi::get_one::<Vec<Option<f64>>>(
            r#"
            SELECT
                vector_selector(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ
                , 50 * 60 * 1000
                , 50 * 60 * 1000
                , t
                , v order by t)
            FROM gfv_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, vec![Some(0_f64), Some(100_f64)]);
    }

    #[pg_test]
    fn test_vector_selector_three() {
        setup();
        let result = Spi::get_one::<Vec<Option<f64>>>(
            r#"
            SELECT
                vector_selector(
                  '2000-01-02T14:55:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ
                , 50 * 60 * 1000
                , 50 * 60 * 1000
                , t
                , v order by t)
            FROM gfv_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, vec![None, Some(90_f64)]);
    }

    #[pg_test]
    fn test_vector_selector_two() {
        setup();
        let result = Spi::get_one::<Vec<Option<f64>>>(
            r#"
            SELECT
                vector_selector(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ
                , 10 * 60 * 1000
                , 10 * 60 * 1000
                , t
                , v order by t)
            FROM gfv_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(
            result,
            vec![
                Some(0_f64),
                Some(20_f64),
                Some(40_f64),
                Some(60_f64),
                Some(80_f64),
                Some(100_f64)
            ]
        );
    }
}
