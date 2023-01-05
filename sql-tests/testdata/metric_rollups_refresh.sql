\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(10);

SELECT prom_api.set_default_chunk_interval(INTERVAL '1 hour');

\i 'testdata/scripts/generate-test-metric.sql'

-- Create metric rollups.
CALL _prom_catalog.create_rollup('short', INTERVAL '5 minutes', INTERVAL '1 day');
CALL _prom_catalog.create_rollup('long', INTERVAL '1 hour', INTERVAL '1 day');

-- Check refresh jobs.
SELECT ok(EXISTS(SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = INTERVAL '5 minutes') = false);
SELECT ok(EXISTS(SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = INTERVAL '1 hour') = false);

CALL _prom_catalog.scan_for_new_rollups(1, '{}'::jsonb);

-- Check refresh jobs.
SELECT ok(EXISTS(SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = INTERVAL '5 minutes') = true);
SELECT ok(EXISTS(SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = INTERVAL '1 hour') = true);

-- Count the samples in respective resolutions.
SELECT ok(count(*) = 2017, 'samples in 5m metric-rollup') FROM ps_short.test;
SELECT ok(count(*) = 169, 'samples in 1h metric-rollup') FROM ps_long.test;

-- Now, imagine that Prometheus adds data for last 2 hours.
INSERT INTO prom_data.test
SELECT
    time,
    floor(random()*1000) AS value,
    _prom_catalog.get_or_create_series_id('{"__name__": "test", "job":"promscale", "instance": "localhost:9090"}')
FROM generate_series(
    current_timestamp - INTERVAL '5 hours', -- Start generating samples from 18 hours, since execute_caggs_refresh_policy skips the recent 2 chunks_interval data when refreshing so as to refresh only on inactive chunks.
    current_timestamp,
    interval '30 seconds'
) as time;

-- # TEST refreshing metric-rollups.

-- Check samples before calling the refresh func.
SELECT ok(count(*) = 2017, 'samples in 5m metric-rollup') FROM ps_short.test;
SELECT ok(count(*) = 169, 'samples in 1h metric-rollup') FROM ps_long.test;

DO $$
BEGIN
    CALL _prom_catalog.execute_caggs_refresh_policy(1, json_build_object('refresh_interval', interval '5 minutes')::jsonb);
    CALL _prom_catalog.execute_caggs_refresh_policy(2, json_build_object('refresh_interval', interval '1 hour')::jsonb);
END;
$$;

SELECT ok(count(*) = 2018, 'samples in 5m metric-rollup') FROM ps_short.test; -- Note: Only 1 sample increased, since refresh only accounts for 1 bucket
SELECT ok(count(*) = 170, 'samples in 1h metric-rollup') FROM ps_long.test; -- Same as above.

-- The end
SELECT * FROM finish(true);