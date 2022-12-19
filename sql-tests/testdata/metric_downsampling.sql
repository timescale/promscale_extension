\set ON_ERROR_STOP 1

-- Ensure the state before creating downsampling data.
SELECT * from _prom_catalog.downsample;
SELECT EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ds_5m');

DO $$
BEGIN
    PERFORM _prom_catalog.get_or_create_metric_table_name('test');
    INSERT INTO _prom_catalog.metadata VALUES (to_timestamp(0), 'test', 'GAUGE', '', 'Test metric.');
END;
$$;

-- Create a metric downsampling.
CALL _prom_catalog.create_downsampling('ds_5m', INTERVAL '5 minutes', INTERVAL '30 days');

-- Ensure the state after downsampling cfg is created.
SELECT * from _prom_catalog.downsample;
SELECT EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ds_5m');

-- Ensure the state before scanning for new rollups.
SELECT * from _prom_catalog.metric_downsample;

SELECT * FROM _prom_catalog.metric;

-- Scan and create the Caggs.
CALL _prom_catalog.scan_for_new_downsampling_views(1, '{}'::jsonb);

SELECT * FROM _prom_catalog.metric;

-- Ensure the state after scanning for new rollups.
SELECT * from _prom_catalog.metric_downsample;

-- Disable downsampling.
SELECT _prom_catalog.update_downsampling_state('ds_5m', false);
SELECT * FROM _prom_catalog.downsample;
SELECT _prom_catalog.update_downsampling_state('ds_5m', true);
SELECT * FROM _prom_catalog.downsample;

-- Delete the metric downsampling.
CALL _prom_catalog.delete_downsampling('ds_5m');

-- Nothing should exist.
SELECT * from _prom_catalog.downsample;
SELECT * from _prom_catalog.metric_downsample;
SELECT * FROM _prom_catalog.metric;
SELECT EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ds_5m');
