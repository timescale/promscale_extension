\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(10);

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

-- Compress again to ensure we don't error when touching compressed chunks.
SET client_min_messages to 'WARNING'; -- So that the snapshot does not get filled with debug logs.
CALL _prom_catalog.execute_caggs_compression_policy(3, '{}'::jsonb);

-- # Test retaining metric-rollups.

SELECT ok(count(*) > 0) FROM (SELECT show_chunks('ps_short.test')) a;
SELECT ok(count(*) > 0) FROM (SELECT show_chunks('ps_long.test')) a;

-- Perform retention.
CALL _prom_catalog.execute_caggs_retention_policy(4, '{}'::jsonb); -- Retention removes all the chunks since retention interval is 1 day and the data was ingested a month

SELECT ok(count(*) = 0) FROM (SELECT show_chunks('ps_short.test')) a;
SELECT ok(count(*) = 0) FROM (SELECT show_chunks('ps_long.test')) a;

-- The end
SELECT * FROM finish(true);