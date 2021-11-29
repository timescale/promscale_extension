use std::collections::VecDeque;

use pgx::*;

use pgx::{error, pg_sys::TimestampTz};

mod aggregate_utils;
mod palloc;
mod type_builder;

use aggregate_utils::in_aggregate_context;

use palloc::Internal;

type Milliseconds = i64;
type Microseconds = i64;
const USECS_PER_SEC: i64 = 1_000_000;
const USECS_PER_MS: i64 = 1_000;

const STALE_NAN: u64 = 0x7ff0000000000002;

// prom divides time into sliding windows of fixed size, e.g.
// |  5 seconds  |  5 seconds  |  5 seconds  |  5 seconds  |  5 seconds  |
// we take the first and last values in that bucket and uses `last-first` as the
// value for that bucket.
//  | a b c d e | f g h i | j   k |   m    |
//  |   e - a   |  i - f  | k - j | <null> |
#[allow(clippy::too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn prom_delta_transition(
    state: Option<Internal<GapfillDeltaTransition>>,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds, // `prev_now - step` is where the next window starts
    range: Milliseconds,     // the size of a window to delta over
    time: TimestampTz,
    val: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Option<Internal<GapfillDeltaTransition>> {
    unsafe {
        in_aggregate_context(fc, || {
            if time < lowest_time || time > greatest_time {
                error!("input time less than lowest time")
            }

            let mut state = state.unwrap_or_else(|| {
                let state: Internal<_> = GapfillDeltaTransition::new(
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

            state.add_data_point(time, val);

            Some(state)
        })
    }
}

#[allow(clippy::too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn prom_rate_transition(
    state: Option<Internal<GapfillDeltaTransition>>,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds,
    range: Milliseconds, // the size of a window to calculate over
    time: TimestampTz,
    val: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Option<Internal<GapfillDeltaTransition>> {
    unsafe {
        in_aggregate_context(fc, || {
            if time < lowest_time || time > greatest_time {
                error!("input time less than lowest time")
            }

            let mut state = state.unwrap_or_else(|| {
                let state: Internal<_> = GapfillDeltaTransition::new(
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

#[allow(clippy::too_many_arguments)]
#[pg_extern(immutable, parallel_safe)]
pub fn prom_increase_transition(
    state: Option<Internal<GapfillDeltaTransition>>,
    lowest_time: TimestampTz,
    greatest_time: TimestampTz,
    step_size: Milliseconds, // `prev_now - step` is where the next window starts
    range: Milliseconds,     // the size of a window to delta over
    time: TimestampTz,
    val: f64,
    fc: pg_sys::FunctionCallInfo,
) -> Option<Internal<GapfillDeltaTransition>> {
    unsafe {
        in_aggregate_context(fc, || {
            if time < lowest_time || time > greatest_time {
                error!("input time less than lowest time")
            }

            let mut state = state.unwrap_or_else(|| {
                let state: Internal<_> = GapfillDeltaTransition::new(
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

#[pg_extern()]
pub fn prom_delta_final(
    state: Option<Internal<GapfillDeltaTransition>>,
) -> Option<Vec<Option<f64>>> {
    state.map(|mut s| s.to_vec())
}

#[derive(Debug)]
pub struct GapfillDeltaTransition {
    window: VecDeque<(TimestampTz, f64)>,
    // a Datum for each index in the array, 0 by convention if the value is NULL
    deltas: Vec<Option<f64>>,
    current_window_max: TimestampTz,
    current_window_min: TimestampTz,
    step_size: Microseconds,
    range: Microseconds,
    greatest_time: TimestampTz,
    is_counter: bool,
    is_rate: bool,
}

impl GapfillDeltaTransition {
    pub fn new(
        lowest_time: TimestampTz,
        greatest_time: TimestampTz,
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

    fn add_data_point(&mut self, time: TimestampTz, val: f64) {
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

    fn in_current_window(&self, time: TimestampTz) -> bool {
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

        result_val *= extrapolate_to_interval / sampled_interval;

        if self.is_rate {
            result_val /= (self.range / USECS_PER_SEC) as f64
        }

        self.deltas.push(Some(result_val));
    }

    pub fn to_vec(&mut self) -> Vec<Option<f64>> {
        while self.current_window_max <= self.greatest_time {
            self.flush_current_window();
        }
        self.deltas.clone()
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
    fcinfo: pg_sys::FunctionCallInfo,
) -> Option<Internal<VectorSelector>> {
    let fcinfo = unsafe { fcinfo.as_mut() }.unwrap();
    let nargs = fcinfo.nargs;
    let len = std::mem::size_of::<pg_sys::NullableDatum>() * nargs as usize;
    let args = unsafe { fcinfo.args.as_slice(len) };

    let state = unsafe { Internal::from_datum(args[0].value, args[0].isnull, pg_sys::INTERNALOID) };
    let start_time =
        unsafe { TimestampTz::from_datum(args[1].value, args[1].isnull, pg_sys::TIMESTAMPTZOID) }
            .unwrap_or_else(|| error!("start_time is null"));
    let end_time =
        unsafe { TimestampTz::from_datum(args[2].value, args[2].isnull, pg_sys::TIMESTAMPTZOID) }
            .unwrap_or_else(|| error!("end_time is null"));

    let bucket_width =
        unsafe { Milliseconds::from_datum(args[3].value, args[3].isnull, pg_sys::INT8OID) }
            .unwrap_or_else(|| error!("bucket_width is null"));

    let lookback =
        unsafe { Milliseconds::from_datum(args[4].value, args[4].isnull, pg_sys::INT8OID) }
            .unwrap_or_else(|| error!("lookback is null"));

    let time =
        unsafe { TimestampTz::from_datum(args[5].value, args[5].isnull, pg_sys::TIMESTAMPTZOID) }
            .unwrap_or_else(|| error!("time is null"));

    let value = unsafe { f64::from_datum(args[6].value, args[6].isnull, pg_sys::FLOAT8OID) }
        .unwrap_or_else(|| error!("value is null"));

    unsafe {
        in_aggregate_context(fcinfo, || {
            let mut state = state.unwrap_or_else(|| {
                let state: Internal<_> =
                    VectorSelector::new(start_time, end_time, bucket_width, lookback).into();
                state
            });

            state.insert(time, value);

            Some(state)
        })
    }
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_final(state: Option<Internal<VectorSelector>>) -> Option<Vec<Option<f64>>> {
    state.map(|s| s.to_pg_array())
}

#[allow(non_camel_case_types)]
pub type bytea = pg_sys::Datum;

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_serialize(state: Internal<VectorSelector>) -> bytea {
    crate::do_serialize!(state)
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_deserialize(
    bytes: bytea,
    _internal: Option<Internal<()>>,
) -> Internal<VectorSelector> {
    crate::do_deserialize!(bytes, VectorSelector)
}

#[pg_extern(immutable, parallel_safe)]
pub fn vector_selector_combine(
    state1: Option<Internal<VectorSelector>>,
    state2: Option<Internal<VectorSelector>>,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Option<Internal<VectorSelector>> {
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
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct VectorSelector {
    first_bucket_max_time: TimestampTz,
    last_bucket_max_time: TimestampTz,
    end_time: TimestampTz, //only used for error checking
    bucket_width: Milliseconds,
    lookback: Milliseconds,
    elements: Vec<Option<(TimestampTz, f64)>>,
}

impl VectorSelector {
    pub fn new(
        start_time: TimestampTz,
        end_time: TimestampTz,
        bucket_width: Milliseconds,
        lookback: Milliseconds,
    ) -> Self {
        let num_buckets = ((end_time - start_time) / (bucket_width * USECS_PER_MS)) + 1;

        let last_bucket_max_time =
            end_time - ((end_time - start_time) % (bucket_width * USECS_PER_MS));

        VectorSelector {
            first_bucket_max_time: start_time,
            last_bucket_max_time,
            end_time,
            bucket_width,
            lookback,
            elements: vec![None; num_buckets as usize],
        }
    }

    fn combine(&mut self, other: &Internal<VectorSelector>) {
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
                    let (my_t, _): (TimestampTz, f64) = mine;
                    let (other_t, _): (TimestampTz, f64) = *other;
                    if other_t > my_t {
                        *s = Some(*other)
                    }
                }
            }
        }
    }

    fn insert(&mut self, time: TimestampTz, val: f64) {
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

    fn get_bucket(&self, time: TimestampTz) -> usize {
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
                None => {
                    if let Some(tuple) = last {
                        let (t, v): (TimestampTz, f64) = tuple;
                        if t >= ts - (self.lookback * USECS_PER_MS) && v.to_bits() != STALE_NAN {
                            pushed = true;
                            vals.push(Some(v));
                        }
                    }
                }
                Some(tuple) => {
                    let (t, v2): &(TimestampTz, f64) = tuple;
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
            ts += self.bucket_width * USECS_PER_MS
        }

        vals
    }

    pub fn to_pg_array(&self) -> Vec<Option<f64>> {
        self.results()
    }
}

extension_sql!(
    r#"
CREATE AGGREGATE vector_selector(
    start_time timestamptz,
    end_time timestamptz,
    bucket_width bigint,
    lookback bigint,
    sample_time timestamptz,
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
    name = "create_aggregate_vector_selector"
);
