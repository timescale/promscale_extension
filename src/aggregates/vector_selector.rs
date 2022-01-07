//! # Vector Selector
//! The `vector_selector` aggregate implements Prometheus' `VectorSelector` processing.
//!
//! ## Instant Vector
//! A Prometheus `Instant Vector` is a set of time series, each with a single data point. The single
//! data point of each series is determined by looking back over a window of time (`lookback`) from
//! the reference point `t` and retrieving the most recent sample.
//!
//! As an example, we see that given an evaluation time `t`, we look back on the timeseries `ts`
//! over a window of size `lookback` for the most recent sample, in this case `e`.
//!
//! ```text
//!                          t
//!                          |
//!  ts:  a b   c    d   e     f  g
//!                      ^
//! out:                     e
//!          |---lookback----|
//! ```
//!
//! ## Range Queries
//!
//! This can be applied over a time range to determine a range of `Instant Vector`s, i.e. an
//! `Instant Vector` for multiple reference points `(t_1, t_2, ..., t_n)`.
//!
//! The range query is determined by a `start_time`, an `end_time`, a `bucket_width`, and
//! `lookback`. These dictate the times `t_i` at which we look back over the time series to find
//! the most recent sample.
//!
//! As an example, for the range [`t_1, t_3`], and `bucket_width`, each of the points in time `t_1`,
//! `t_2`, `t_3` is separated by `bucket_width`, and uses `lookback` to look back over the time
//! series and determine the most recent sample.
//!
//! ```text
//!                         t_1                  t_2                  t_3
//!                          |----bucket_width----|                    |
//!                          |                    |                    |
//!  ts:  a b   c    d   e     f  g    h      i   j    k
//!                      ^---|                    ^     x--------------|
//! out:                     e                    j                    Ø
//!           |---lookback---|     |---lookback---|     |---lookback---|
//! ```
//!
//! ## Vector Selector
//!
//! Both a single and a range of `Instant Vector`s can be obtained with the `Vector Selector`.
//!
//! # Usage from SQL
//!
//! The pseudo-SQL definition of the `vector_selector` aggregate is:
//!
//! ```sql
//! FUNCTION vector_selector(
//!   start_time TIMESTAMPTZ
//! , end_time TIMESTAMPTZ,
//! , bucket_width BIGINT
//! , lookback BIGINT
//! , sample_time TIMESTAMPTZ
//! , sample_value DOUBLE PRECISION
//! )
//! RETURNS DOUBLE PRECISION[]
//! ```
//!
//! The parameters `start_time`, `end_time`, `bucket_width`, and `lookback` function as described
//! above. `bucket_width` and `lookback` are specified in milliseconds. The parameters `sample_time`
//! and `sample_value` are values in the underlying timeseries which is being aggregated over.
//!
//! The vector selector returns an array containing _only_ the sample values for each window, or
//! `NULL` if there was no sample present for a given window. Note: it does not return any
//! timestamps.
//!
//! Note: The `vector_selector` aggregate expects to be evaluated over time series data in the range
//! [`start_time` - `lookback`, `end_time`]. If any of the values of `sample_time` is _outside_ of
//! this range, the aggregate will raise a Postgres ERROR.
//!
//! ## Example SQL query
//!
//! First, we assume a table `test_table` with the following definition:
//!
//! ```sql
//! CREATE TABLE test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
//! ```
//!
//! We can then invoke the `vector_selector` aggregate on this table
//!
//! ```sql
//! SELECT
//!     vector_selector(
//!       '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
//!     , '2000-01-02T15:10:00+00:00'::TIMESTAMPTZ
//!     , 10 * 60 * 1000
//!     , 10 * 60 * 1000
//!     , t
//!     , v)
//! FROM test_table
//! WHERE t >= '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ - '10 minutes'::INTERVAL
//!   AND t <= '2000-01-02T15:10:00+00:00'::TIMESTAMPTZ
//! ```
//!
//! Here we define that we want to determine the `Instant Vector`s for the range
//! [2000-01-02T15:00:00+00:00, 2000-01-02T15:10:00+00:00], in 10 minute buckets, and looking back
//! over 10 minutes of data. Note that we restrict the data being aggregated over to correspond to
//! the arguments which we have passed to `vector_selector`.
//!
//! If `test_table` contained the following values:
//! ```text
//!            t            |  v
//! ------------------------+-----
//!  2000-01-02 15:00:00+00 |   0
//!  2000-01-02 15:05:00+00 |  10
//! ```
//!
//! The output of the above `vector_selector` query would be:
//!
//! ```text
//!  vector_selector
//! -----------------
//!  {0,20}
//! (1 row)
//! ```
//!
//! We could modify the above query to obtain a single `Instant Vector` for the timestamp
//! '2000-01-02T15:00:00+00:00' with:
//!
//! ```sql
//! SELECT
//!     vector_selector(
//!       '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
//!     , '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
//!     , 0
//!     , 10 * 60 * 1000
//!     , t
//!     , v)
//! FROM test_table
//! WHERE t >= '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ - '10 minutes'::INTERVAL
//!   AND t <= '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
//! ```
//!
use pgx::*;

use pgx::error;

use crate::aggregates::{Milliseconds, STALE_NAN, USECS_PER_MS};
use serde::{Deserialize, Serialize};

/// The internal state consists of a vector non-overlapping sample buckets. Each bucket
/// has a corresponding (virtual) timestamp corresponding to the ts series
/// described above. The timestamp represents the maximum value stored in the
/// bucket (inclusive). The minimum value is defined by the maximum value of
/// the previous bucket (exclusive).
/// the value stored inside the bucket is the last sample in the bucket (sample with highest timestamp)
#[allow(non_camel_case_types)]
#[derive(Debug, Clone, Serialize, Deserialize, PostgresType)]
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
            last_bucket_max_time,
            end_time,
            bucket_width,
            lookback,
            elements: vec![None; num_buckets as usize],
        }
    }

    fn combine_with(&mut self, other: &VectorSelector) {
        if self.first_bucket_max_time != other.first_bucket_max_time
            || self.last_bucket_max_time != other.last_bucket_max_time
            || self.end_time != other.end_time
            || self.bucket_width != other.bucket_width
            || self.lookback != other.lookback
            || self.elements.len() != other.elements.len()
        {
            error!("trying to combine incompatible vector selectors")
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
                None => {
                    if let Some(tuple) = last {
                        let (t, v): (pg_sys::TimestampTz, f64) = tuple;
                        if t >= ts - (self.lookback * USECS_PER_MS) && v.to_bits() != STALE_NAN {
                            pushed = true;
                            vals.push(Some(v));
                        }
                    }
                }
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
            ts += self.bucket_width * USECS_PER_MS
        }

        vals
    }

    pub fn to_pg_array(&self) -> Vec<Option<f64>> {
        self.results()
    }
}

#[pg_aggregate]
impl Aggregate for VectorSelector {
    type State = Option<Self>;
    type Args = (
        name!(lowest_time, pg_sys::TimestampTz),
        name!(greatest_time, pg_sys::TimestampTz),
        name!(bucket_width, Milliseconds),
        name!(lookback, Milliseconds),
        name!(sample_time, pg_sys::TimestampTz),
        name!(sample_value, f64),
    );
    type Finalize = Option<Vec<Option<f64>>>;

    const PARALLEL: Option<ParallelOption> = Some(ParallelOption::Safe);

    const NAME: &'static str = "vector_selector";

    fn state(
        state: Self::State,
        (start_time, end_time, bucket_width, lookback, time, value): Self::Args,
        _: pg_sys::FunctionCallInfo,
    ) -> Self::State {
        let mut state = state
            .unwrap_or_else(|| VectorSelector::new(start_time, end_time, bucket_width, lookback));

        state.insert(time, value);

        Some(state)
    }

    fn finalize(
        current: Self::State,
        _: Self::OrderedSetArgs,
        _: pg_sys::FunctionCallInfo,
    ) -> Self::Finalize {
        current.map(|c| c.to_pg_array())
    }

    fn combine(
        state1: Self::State,
        state2: Self::State,
        _: pg_sys::FunctionCallInfo,
    ) -> Self::State {
        match (state1, state2) {
            (None, None) => None,
            (None, Some(state2)) => Some(state2),
            (Some(state1), None) => Some(state1),
            (Some(mut state1), Some(state2)) => {
                state1.combine_with(&state2);
                Some(state1)
            }
        }
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;
    use serde_json::Value;

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

    /// ```text
    ///                          t_1                 t_2
    ///                           |----bucket_width---|
    ///                           |                   |
    ///  ts:                      a b c d e f g h i j k
    ///                           ^                   ^
    /// out:                      a                   k
    ///       |------lookback-----|------lookback-----|
    /// ```
    #[pg_test]
    fn test_vector_selector_bucket_and_lookback_size_exact_match_beginning_end() {
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

    /// ```text
    ///                   t_1                  t_2                  t_3
    ///                    |----bucket_width----|----bucket_width----|
    ///                    |                    |                    |
    ///  ts:        a    b   c                             d
    ///                  ^-|       x------------|          ^---------|
    /// out:               b                    Ø                    d
    ///       |--lookback--|       |--lookback--|       |--lookback--|
    /// ```
    #[pg_test]
    fn test_vector_selector_lookback_smaller_than_bucket_with_and_without_results_in_lookback() {
        Spi::run(
            r#"
            CREATE TABLE gfv_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfv_test_table (t, v) VALUES
                ('2000-01-02T14:58:00+00:00',0),
                ('2000-01-02T14:59:00+00:00',10),
                ('2000-01-02T15:01:00+00:00',20),
                ('2000-01-02T15:09:00+00:00',30);
        "#,
        );
        let result = Spi::get_one::<Vec<Option<f64>>>(
            r#"
            SELECT
                vector_selector(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:10:00+00:00'::TIMESTAMPTZ
                , 5 * 60 * 1000
                , 2 * 60 * 1000
                , t
                , v order by t)
            FROM gfv_test_table
            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(result, vec![Some(10_f64), None, Some(30_f64)]);
    }

    /// ```text
    ///                             t_1            t_2            t_3            t_4
    ///                              |-bucket_width-|-bucket_width-|-bucket_width-|
    ///                              |              |              |              |
    ///  ts:                     a                            b
    ///                          ^---|--------------|         ^----|--------------|
    /// out:                         a              a              b              b
    ///       |-------lookback-------|
    ///                      |-------lookback-------|
    ///                                     |-------lookback-------|
    /// ```                                                |-------lookback-------|
    #[pg_test]
    fn test_vector_selector_lookback_larger_than_bucket_width() {
        setup();
        let result = Spi::get_one::<Vec<Option<f64>>>(
            r#"
            SELECT
                vector_selector(
                  '2000-01-02T15:00:30+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:08:00+00:00'::TIMESTAMPTZ
                , 150 * 1000
                , 180 * 1000
                , t
                , v order by t)
            FROM gfv_test_table
            WHERE t >= '2000-01-02T15:00:30+00:00'::TIMESTAMPTZ - '180 SECONDS'::INTERVAL
              AND t <= '2000-01-02T15:08:00+00:00'::TIMESTAMPTZ

            ;"#,
        )
        .expect("SQL query failed");
        assert_eq!(
            result,
            vec![Some(0_f64), Some(0_f64), Some(10_f64), Some(10_f64)]
        );
    }

    /// ```text
    ///                          t_1                 t_2
    ///                           |----bucket_width---|
    ///                           |                   |
    ///  ts:                        a b c d e f g h i j k
    ///         x-----------------|                   ^
    /// out:                      Ø                   j
    ///       |------lookback-----|------lookback-----|
    /// ```
    #[pg_test]
    fn test_vector_selector_start_end_not_aligned_with_timeseries_data() {
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

    /// ```text
    ///                    t_1                 t_6
    /// bucket_widths:      |---|---|---|---|---|
    ///                     |   |   |   |   |   |
    ///            ts:      a b c d e f g h i j k
    ///                     ^   ^   ^   ^   ^   ^
    ///           out:      a   c   e   g   i   k
    ///     lookbacks:  |---|---|---|---|---|---|
    /// ```
    #[pg_test]
    fn test_vector_selector_smaller_bucket_and_lookback_size() {
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

    /// ```text
    ///                    t_1                 t_6
    /// bucket_widths:      |---|---|---|---|---|
    ///                     |   |   |   |   |   |
    ///            ts:      a b c d e f g h i j k
    ///                     ^   ^   ^   ^   ^   ^
    ///           out:      a   c   e   g   i   k
    ///     lookbacks:  |---|---|---|---|---|---|
    /// ```
    #[pg_test]
    fn test_vector_selector_smaller_bucket_and_lookback_size_randomized_input() {
        setup();
        Spi::run(
            r#"
            CREATE TABLE gfv_rand_test_table AS SELECT * FROM gfv_test_table ORDER BY RANDOM();
            "#,
        );
        let result = Spi::get_one::<Vec<Option<f64>>>(
            r#"
            SELECT
                vector_selector(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ
                , 10 * 60 * 1000
                , 10 * 60 * 1000
                , t
                , v)
            FROM gfv_rand_test_table
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

    /// ```text
    ///                    t_1                 t_6
    /// bucket_widths:      |---|---|---|---|---|
    ///                     |   |   |   |   |   |
    ///            ts:      a b c d e f g h i j k
    ///                     ^   ^   ^   ^   ^   ^
    ///           out:      a   c   e   g   i   k
    ///     lookbacks:  |---|---|---|---|---|---|
    /// ```
    #[pg_test]
    fn test_vector_selector_parallel_execution_smaller_bucket_lookback() {
        setup();

        // Force parallel execution
        Spi::run(
            r#"
            SET max_parallel_workers = 6;
            SET max_parallel_workers_per_gather = 6;
            SET parallel_leader_participation = off;
            SET parallel_tuple_cost = 0;
            SET parallel_setup_cost = 0;
            SET min_parallel_table_scan_size = 0;
            "#,
        );

        let query = r#"
            SELECT
                vector_selector(
                  '2000-01-02T15:00:00+00:00'::TIMESTAMPTZ
                , '2000-01-02T15:50:00+00:00'::TIMESTAMPTZ
                , 10 * 60 * 1000
                , 10 * 60 * 1000
                , t
                , v)
            FROM gfv_test_table
            ;"#;

        let parallel_plan =
            Spi::get_one::<Json>(format!("EXPLAIN (COSTS OFF, FORMAT JSON) {}", query).as_str())
                .expect("SQL query failed");

        // Assert that we're running in parallel mode.
        // Note: this query plan is specific to PG14.
        assert_eq!(
            parallel_plan.0,
            serde_json::from_str::<Value>(
                r#"
                 [
                   {
                     "Plan": {
                       "Node Type": "Aggregate",
                       "Strategy": "Plain",
                       "Partial Mode": "Finalize",
                       "Parallel Aware": false,
                       "Async Capable": false,
                       "Plans": [
                         {
                           "Node Type": "Gather",
                           "Parent Relationship": "Outer",
                           "Parallel Aware": false,
                           "Async Capable": false,
                           "Workers Planned": 3,
                           "Single Copy": false,
                           "Plans": [
                             {
                               "Node Type": "Aggregate",
                               "Strategy": "Plain",
                               "Partial Mode": "Partial",
                               "Parent Relationship": "Outer",
                               "Parallel Aware": false,
                               "Async Capable": false,
                               "Plans": [
                                 {
                                   "Node Type": "Seq Scan",
                                   "Parent Relationship": "Outer",
                                   "Parallel Aware": true,
                                   "Async Capable": false,
                                   "Relation Name": "gfv_test_table",
                                   "Alias": "gfv_test_table"
                                 }
                               ]
                             }
                           ]
                         }
                       ]
                     }
                   }
                 ]
                "#
            )
            .unwrap()
        );

        let result = Spi::get_one::<Vec<Option<f64>>>(query).expect("SQL query failed");
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
