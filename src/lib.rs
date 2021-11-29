use std::collections::VecDeque;

use pgx::*;

use pgx::error;

use aggregate_utils::in_aggregate_context;
use serde::{Deserialize, Serialize};

use crate::palloc::{Inner, InternalAsValue, ToInternal};
use crate::raw::{bytea, TimestampTz};

mod aggregate_utils;
mod palloc;
mod prom_agg;
mod raw;
mod support;
mod type_builder;

pg_module_magic!();

type Milliseconds = i64;
type Microseconds = i64;
const USECS_PER_SEC: i64 = 1_000_000;
const USECS_PER_MS: i64 = 1_000;

const STALE_NAN: u64 = 0x7ff0000000000002;

#[pg_extern(immutable, parallel_safe)]
pub fn prom_rate_transition(
    state: Internal,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds,
    range: Milliseconds, // the size of a window to calculate over
    time: TimestampTz,
    val: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Internal {
    prom_rate_transition_inner(
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

pub fn prom_rate_transition_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
    lowest_time: pg_sys::TimestampTz,
    greatest_time: pg_sys::TimestampTz,
    step_size: Milliseconds,
    range: Milliseconds, // the size of a window to calculate over
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
                    true,
                )
                .into();
                state
            });

            state.add_data_point(time, val);

            Some(state)
        })
    }
}

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

#[derive(Serialize, Deserialize, PostgresType, Debug)]
pub struct GapfillDeltaTransition {
    window: VecDeque<(pg_sys::TimestampTz, f64)>,
    // a Datum for each index in the array, 0 by convention if the value is NULL
    deltas: Vec<Option<f64>>,
    current_window_max: pg_sys::TimestampTz,
    current_window_min: pg_sys::TimestampTz,
    step_size: Microseconds,
    range: Microseconds,
    greatest_time: pg_sys::TimestampTz,
    is_counter: bool,
    is_rate: bool,
}

impl GapfillDeltaTransition {
    pub fn new(
        lowest_time: pg_sys::TimestampTz,
        greatest_time: pg_sys::TimestampTz,
        range: Milliseconds,
        step_size: Milliseconds,
        is_counter: bool,
        is_rate: bool,
    ) -> Self {
        let mut expected_deltas = (greatest_time - lowest_time) / (step_size * USECS_PER_MS);
        if (greatest_time - lowest_time) % (step_size * USECS_PER_MS) != 0 {
            expected_deltas += 1
        }
        GapfillDeltaTransition {
            window: VecDeque::default(),
            deltas: Vec::with_capacity(expected_deltas as usize),
            current_window_max: lowest_time + range * USECS_PER_MS,
            current_window_min: lowest_time,
            step_size: step_size * USECS_PER_MS,
            range: range * USECS_PER_MS,
            greatest_time,
            is_counter,
            is_rate,
        }
    }

    fn add_data_point(&mut self, time: pg_sys::TimestampTz, val: f64) {
        // skip stale NaNs
        if val.to_bits() == STALE_NAN {
            return;
        }

        while !self.in_current_window(time) {
            self.flush_current_window()
        }

        if self.window.back().map_or(false, |(prev, _)| *prev > time) {
            error!("inputs must be in ascending time order")
        }
        if time >= self.current_window_min {
            self.window.push_back((time, val));
        }
    }

    fn in_current_window(&self, time: pg_sys::TimestampTz) -> bool {
        time <= self.current_window_max
    }

    fn flush_current_window(&mut self) {
        self.add_delta_for_current_window();

        self.current_window_min += self.step_size;
        self.current_window_max += self.step_size;

        let current_window_min = self.current_window_min;
        while self
            .window
            .front()
            .map_or(false, |(time, _)| *time < current_window_min)
        {
            self.window.pop_front();
        }
    }

    //based on extrapolatedRate
    // https://github.com/prometheus/prometheus/blob/e5ffa8c9a08a5ee4185271c8c26051ddc1388b7a/promql/functions.go#L59
    fn add_delta_for_current_window(&mut self) {
        if self.window.len() < 2 {
            // if there are 1 or fewer values in the window, store NULL
            self.deltas.push(None);
            return;
        }

        let mut counter_correction = 0.0;
        if self.is_counter {
            let mut last_value = 0.0;
            for (_, sample) in &self.window {
                if *sample < last_value {
                    counter_correction += last_value
                }
                last_value = *sample
            }
        }

        let (latest_time, latest_val) = self.window.back().cloned().unwrap();
        let (earliest_time, earliest_val) = self.window.front().cloned().unwrap();
        let mut result_val = latest_val - earliest_val + counter_correction;

        // all calculated durations and interval are in seconds
        let mut duration_to_start =
            (earliest_time - self.current_window_min) as f64 / USECS_PER_SEC as f64;
        let duration_to_end = (self.current_window_max - latest_time) as f64 / USECS_PER_SEC as f64;

        let sampled_interval = (latest_time - earliest_time) as f64 / USECS_PER_SEC as f64;
        let avg_duration_between_samples = sampled_interval as f64 / (self.window.len() - 1) as f64;

        if self.is_counter && result_val > 0.0 && earliest_val >= 0.0 {
            // Counters cannot be negative. If we have any slope at
            // all (i.e. result_val went up), we can extrapolate
            // the zero point of the counter. If the duration to the
            // zero point is shorter than the durationToStart, we
            // take the zero point as the start of the series,
            // thereby avoiding extrapolation to negative counter
            // values.
            let duration_to_zero = sampled_interval * (earliest_val / result_val);
            if duration_to_zero < duration_to_start {
                duration_to_start = duration_to_zero
            }
        }

        // If the first/last samples are close to the boundaries of the range,
        // extrapolate the result. This is as we expect that another sample
        // will exist given the spacing between samples we've seen thus far,
        // with an allowance for noise.

        let extrapolation_threshold = avg_duration_between_samples * 1.1;
        let mut extrapolate_to_interval = sampled_interval;

        if duration_to_start < extrapolation_threshold {
            extrapolate_to_interval += duration_to_start
        } else {
            extrapolate_to_interval += avg_duration_between_samples / 2.0
        }

        if duration_to_end < extrapolation_threshold {
            extrapolate_to_interval += duration_to_end
        } else {
            extrapolate_to_interval += avg_duration_between_samples / 2.0
        }

        result_val = result_val * (extrapolate_to_interval / sampled_interval);

        if self.is_rate {
            result_val = result_val / (self.range / USECS_PER_SEC) as f64
        }

        self.deltas.push(Some(result_val));
    }

    pub fn to_vec(&mut self) -> Vec<Option<f64>> {
        while self.current_window_max <= self.greatest_time {
            self.flush_current_window();
        }
        return self.deltas.clone();
    }
}

//a vector selector aggregate has the same semantics as parse.VectorSelector processing
//in Prometheus. Namely, for all timestamps ts in the series:
//     ts := ev.startTimestamp; ts <= ev.endTimestamp; ts += ev.interval
// we return the last sample.value such that the time sample.time <= ts and sample.time >= ts-lookback.
// if such a sample doesn't exist return NULL (None).
// thus, the vector selector returns a regular series of values corresponding to all the points in the
// ts series above.
// Note that for performance, this aggregate is parallel-izable, combinable, and does not expect ordered inputs.
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
pub fn vector_selector_final(state: Internal /* Option<Inner<VectorSelector>> */) -> Internal /* Option<Vec<Option<f64>>> */
{
    let state: Option<Inner<VectorSelector>> = unsafe { state.to_inner() };
    let res = state.map(|s| s.to_pg_array());
    Inner::from(res).internal()
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

//The internal state consists of a vector non-overlapping sample buckets. Each bucket
//has a corresponding (virtual) timestamp corresponding to the ts series
//described above. The timestamp represents the maximum value stored in the
//bucket (inclusive). The minimum value is defined by the maximum value of
//the previous bucket (exclusive).
//the value stored inside the bucket is the last sample in the bucket (sample with highest timestamp)
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

// extension_sql!(
//     r#"
// CREATE AGGREGATE vector_selector(
//     start_time timestamptz,
//     end_time timestamptz,
//     bucket_width bigint,
//     lookback bigint,
//     sample_time timestamptz,
//     sample_value DOUBLE PRECISION)
// (
//     sfunc = vector_selector_transition,
//     stype = internal,
//     finalfunc = vector_selector_final,
//     combinefunc = vector_selector_combine,
//     serialfunc = vector_selector_serialize,
//     deserialfunc = vector_selector_deserialize,
//     parallel = safe
// );
// "#,
//     name = "create_aggregate_vector_selector"
// );

#[cfg(test)]
#[pg_schema]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec![]
    }
}
