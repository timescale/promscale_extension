\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(14);

-- Ensure the state before creating downsampling data.
SELECT ok(count(*) = 0) from _prom_catalog.downsample;
SELECT ok(EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = 'ds_5m') = false);

DO $$
BEGIN
    PERFORM _prom_catalog.get_or_create_metric_table_name('test');
    INSERT INTO _prom_catalog.metadata VALUES (to_timestamp(0), 'test', 'GAUGE', '', 'Test metric.');
END;
$$;

-- Create a metric downsampling.
SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_5m", "ds_interval": "5m", "retention": "30d"}
    ]
$$::jsonb);

-- Ensure the state after downsampling cfg is created.
SELECT ok(count(*) = 1) from _prom_catalog.downsample WHERE should_refresh;
SELECT ok(EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = 'ds_5m') = true);

-- Ensure the state before scanning for new rollups.
SELECT ok(count(*) = 0) from _prom_catalog.metric_downsample;

SELECT ok(count(*) = 1) FROM _prom_catalog.metric;

-- Scan and create the Caggs.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT ok(count(*) = 2) FROM _prom_catalog.metric;

-- Ensure the state after scanning for new rollups.
SELECT ok(count(*) = 1) from _prom_catalog.metric_downsample;

-- Disable downsampling.
SELECT _prom_catalog.apply_downsample_config($$[]$$::jsonb);
SELECT ok(count(*) = 1) FROM _prom_catalog.downsample WHERE schema_name = 'ds_5m' AND NOT should_refresh;
SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_5m", "ds_interval": "5m", "retention": "30d"}
    ]
$$::jsonb);
SELECT _prom_catalog.update_downsampling_state('ds_5m', true);
SELECT ok(count(*) = 1) FROM _prom_catalog.downsample WHERE schema_name = 'ds_5m' AND should_refresh;

-- Delete the metric downsampling.
CALL _prom_catalog.delete_downsampling('ds_5m');

-- Nothing should exist.
SELECT ok(count(*) = 0) from _prom_catalog.downsample;
SELECT ok(count(*) = 0) from _prom_catalog.metric_downsample;
SELECT ok(count(*) = 0) FROM _prom_catalog.metric WHERE is_view;
SELECT ok(EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ds_5m') = false);

-- The end
SELECT * FROM finish(true);