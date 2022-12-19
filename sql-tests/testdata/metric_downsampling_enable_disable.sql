\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(3);

SELECT prom_api.set_downsample_old_data(true);

SELECT prom_api.set_default_chunk_interval(INTERVAL '1 hour');

\i 'testdata/scripts/generate-test-metric.sql'

CALL _prom_catalog.create_downsampling('ds_5m', INTERVAL '5 minutes', INTERVAL '1 day');

SELECT * FROM _prom_catalog.downsample;

CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT ok(count(*) = 2017, 'samples in 5m metric-rollup') FROM ds_5m.test;

SELECT _prom_catalog.update_downsampling_state('ds_5m', false); -- This will make avoid refreshing for ds_5m downsampling.

-- Add new samples.
INSERT INTO prom_data.test
SELECT
    time,
    floor(random()*1000) AS value,
    _prom_catalog.get_or_create_series_id('{"__name__": "test", "job":"promscale", "instance": "localhost:9090"}')
FROM generate_series(
    current_timestamp - interval '4 hours',
    current_timestamp,
    interval '30 seconds'
) as time;

CALL _prom_catalog.execute_caggs_refresh_policy(1, json_build_object('refresh_interval', interval '5 minutes')::jsonb);

SELECT ok(count(*) = 2017, 'samples in 5m metric-rollup') FROM ds_5m.test; -- Samples should be same.


SELECT _prom_catalog.update_downsampling_state('ds_5m', true); -- Now, refreshing caggs should increase samples.

CALL _prom_catalog.execute_caggs_refresh_policy(1, json_build_object('refresh_interval', interval '5 minutes')::jsonb);

SELECT ok(count(*) = 2025, 'samples in 5m metric-rollup') FROM ds_5m.test;

SELECT * FROM finish(true);