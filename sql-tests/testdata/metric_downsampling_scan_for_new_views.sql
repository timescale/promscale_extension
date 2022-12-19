\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(3);

SELECT prom_api.set_downsample_old_data(true);

-- Scan should not error when there are no rollups.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

CALL _prom_catalog.create_downsampling('ds_5m', INTERVAL '5 minutes', INTERVAL '1 day');

-- Scan should not error when there are no metrics.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

\i 'testdata/scripts/generate-test-metric.sql'

-- Scan when there are metrics. This will create new rollups.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT ok(count(*) = 2017) FROM ds_5m.test;

-- Scan again when there aren't any new metrics.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT ok(count(*) = 2017) FROM ds_5m.test;

-- Add a new metric.
DO $$
BEGIN
    PERFORM _prom_catalog.get_or_create_metric_table_name('test_2');
    INSERT INTO _prom_catalog.metadata VALUES (to_timestamp(0), 'test_2', 'GAUGE', '', 'Test metric 2.');

    -- Insert samples for 1 month.
    INSERT INTO prom_data.test_2
    SELECT
        time,
        floor(random()*1000) AS value,
        _prom_catalog.get_or_create_series_id('{"__name__": "test_2", "job":"promscale", "instance": "localhost:9090"}')
    FROM generate_series(
        '2022-10-01 00:00:00',
        '2022-10-08 00:00:00',
        interval '30 seconds'
    ) as time;
END;
$$;

-- Scan for newly added metric test_2.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT ok(count(*) = 2017) FROM ds_5m.test_2;

-- The end
SELECT * FROM finish(true);