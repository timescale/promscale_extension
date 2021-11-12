use std::collections::VecDeque;
use pgx::*;
use pgx::Internal;
use serde::{Deserialize, Serialize};

use crate::{Microseconds, Milliseconds, STALE_NAN, USECS_PER_MS, USECS_PER_SEC};
use crate::palloc::{Inner, InternalAsValue};

mod prom_delta;
mod prom_increase;
mod prom_rate;

#[pg_extern()]
pub fn prom_delta_final(state: Internal) -> Option<Vec<Option<f64>>> {
    prom_delta_final_inner(unsafe { state.to_inner() })
}
pub fn prom_delta_final_inner(
    state: Option<Inner<GapfillDeltaTransition>>,
) -> Option<Vec<Option<f64>>> {
    state.map(|mut s| s.to_vec())
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