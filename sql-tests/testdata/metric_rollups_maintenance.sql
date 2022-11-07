\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(8);

SELECT prom_api.set_default_chunk_interval(INTERVAL '1 hour');

\i 'testdata/scripts/generate-test-metric.sql'

-- Create metric rollups.
CALL _prom_catalog.create_rollup('short', INTERVAL '5 minutes', INTERVAL '1 day');
CALL _prom_catalog.create_rollup('long', INTERVAL '1 hour', INTERVAL '1 day');

CALL _prom_catalog.scan_for_new_rollups(1, '{}'::jsonb);

-- Count the samples in respective resolutions.
SELECT ok(count(*) = 2017, 'samples in 5m metric-rollup') FROM ps_short.test;
SELECT ok(count(*) = 169, 'samples in 1h metric-rollup') FROM ps_long.test;

-- # Test compressing metric-rollups.

\i 'testdata/scripts/test-helpers.sql'

-- Check compressed_chunk_id before calling compress func.
SELECT ok(compressed_chunks_exist('ps_short.test') = false);
SELECT ok(compressed_chunks_exist('ps_long.test') = false);

CALL _prom_catalog.execute_caggs_compression_policy(3, '{}'::jsonb);

-- Look for compressed chunks.
SELECT ok(compressed_chunks_exist('ps_short.test') = true);
SELECT ok(compressed_chunks_exist('ps_long.test') = true);


-- # Test retaining metric-rollups.

DO $$
DECLARE
    _chunks_before_retention_short INTEGER;
    _chunks_before_retention_long INTEGER;

    _chunks_after_retention_short INTEGER;
    _chunks_after_retention_long INTEGER;

BEGIN
    _chunks_before_retention_short := (SELECT count(*) FROM (SELECT show_chunks('ps_short.test')) a);
    _chunks_before_retention_long := (SELECT count(*) FROM (SELECT show_chunks('ps_long.test')) a);

    -- Perform retention.
    CALL _prom_catalog.execute_caggs_retention_policy(4, '{}'::jsonb);

    _chunks_after_retention_short := (SELECT count(*) FROM (SELECT show_chunks('ps_short.test')) a);
    _chunks_after_retention_long := (SELECT count(*) FROM (SELECT show_chunks('ps_long.test')) a);

    PERFORM ok(_chunks_before_retention_short > _chunks_after_retention_short, 'retention for short');
    PERFORM ok(_chunks_before_retention_long > _chunks_after_retention_long, 'retention for long');
END;
$$;

-- The end
SELECT * FROM finish(true);