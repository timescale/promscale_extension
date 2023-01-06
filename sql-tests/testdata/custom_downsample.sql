\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(6);

SELECT prom_api.set_default_chunk_interval(INTERVAL '1 hour');

SELECT prom_api.set_default_retention_period(INTERVAL '1 day');

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

SELECT register_metric_view('custom', 'test', INTERVAL '30 minutes');

-- Check samples in the downsampled view created.
SELECT ok(count(*) = 337, 'samples in custom downsample') FROM custom.test;


-- # Test compressing metric downsampling.

\i 'testdata/scripts/test-helpers.sql'

-- Check compressed_chunk_id before calling compress func.
SELECT ok(compressed_chunks_exist('custom.test') = false);

CALL _prom_catalog.execute_caggs_compression_policy(2, '{}'::jsonb);

-- There shouldn't be any compressed chunks, since the downsampling done manually does not contain timescaledb.compress = true
SELECT ok(compressed_chunks_exist('custom.test') = false);

-- Now imagine if the user enabled compression on his existing Caggs. Let's check if compression now works or not.
ALTER MATERIALIZED VIEW custom.test SET (timescaledb.compress = true);
CALL _prom_catalog.execute_caggs_compression_policy(2, '{}'::jsonb);
SELECT ok(compressed_chunks_exist('custom.test') = true);

-- # Test retaining metric downsampling.

SELECT ok(count(*) > 0) FROM (SELECT show_chunks('custom.test')) a;

-- Perform retention.
CALL _prom_catalog.execute_caggs_retention_policy(3, '{}'::jsonb);

SELECT ok(count(*) = 0) FROM (SELECT show_chunks('custom.test')) a;

-- The end
SELECT * FROM finish(true);