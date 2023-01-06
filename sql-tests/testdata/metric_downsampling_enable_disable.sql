\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(4);

SELECT prom_api.set_downsample_old_data(true);

SELECT prom_api.set_default_chunk_interval(INTERVAL '1 hour');

\i 'testdata/scripts/generate-test-metric.sql'

SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_5m", "ds_interval": "5m", "retention": "1d"}
    ]
$$::jsonb);

SELECT ok(schema_name = 'ds_5m') FROM _prom_catalog.downsample WHERE ds_interval = INTERVAL '5 minutes' AND retention = INTERVAL '1 day';

CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT ok(count(*) = 2017, 'samples in 5m metric-rollup') FROM ds_5m.test;

SELECT _prom_catalog.apply_downsample_config($$[]$$::jsonb); -- This will make avoid refreshing for ds_5m downsampling.

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

SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_5m", "ds_interval": "5m", "retention": "1d"}
    ]
$$::jsonb); -- This will enable the existing ds_5m. Now, refreshing caggs should increase samples.

CALL _prom_catalog.execute_caggs_refresh_policy(1, json_build_object('refresh_interval', interval '5 minutes')::jsonb);

SELECT ok(count(*) = 2025, 'samples in 5m metric-rollup') FROM ds_5m.test;

SELECT * FROM finish(true);