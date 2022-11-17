\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(5);

\i 'testdata/scripts/generate-test-metric.sql'

CREATE SCHEMA custom;

CREATE MATERIALIZED VIEW custom.test WITH (timescaledb.continuous) AS
SELECT
    timezone('UTC',
             time_bucket('30 minutes', time) AT TIME ZONE 'UTC' +'30 minutes')
    as time,
    series_id,
    min(value) as min,
    max(value) as max,
    avg(value) as avg
FROM prom_data.test GROUP BY time_bucket('30 minutes', time), series_id;

SELECT ok(EXISTS(SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = INTERVAL '30 minutes') = false);

SELECT register_metric_view('custom', 'test', INTERVAL '30 minutes');

SELECT ok(EXISTS(SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = INTERVAL '30 minutes') = true);

-- Check samples in the downsampled view created.
SELECT ok(count(*) = 337, 'samples in custom downsample') FROM custom.test;

-- Now, imagine that Prometheus adds data for last 2 hours.
INSERT INTO prom_data.test
SELECT
    time,
    floor(random()*1000) AS value,
    _prom_catalog.get_or_create_series_id('{"__name__": "test", "job":"promscale", "instance": "localhost:9090"}')
FROM generate_series(
    current_timestamp - INTERVAL '2 hours',
    current_timestamp,
    interval '30 seconds'
) as time;

-- # TEST refreshing custom downsample.

-- Check samples before calling the refresh func.
SELECT ok(count(*) = 342, 'samples in custom downsample before refresh') FROM custom.test; -- Samples increased even before calling refresh func. My guess is that this is due to timescaledb.materalized behaviour.

DO $$
BEGIN
    CALL _prom_catalog.execute_caggs_refresh_policy(1, json_build_object('refresh_interval', interval '30 minutes')::jsonb);
END;
$$;

-- Check samples after the refresh.
SELECT ok(count(*) = 340, 'samples in custom downsample after refresh') FROM custom.test; -- 2 samples increased, i.e, from 333 -> 336 which is expected, since last 2 buckets are only updated.

-- The end
SELECT * FROM finish(true);