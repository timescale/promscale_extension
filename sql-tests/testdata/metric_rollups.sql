\set ON_ERROR_STOP 1

-- Ensure the state before rollups creation.
SELECT * from _prom_catalog.rollup;
SELECT EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ps_test');

DO $$
BEGIN
    PERFORM _prom_catalog.get_or_create_metric_table_name('test');
    INSERT INTO _prom_catalog.metadata VALUES (to_timestamp(0), 'test', 'GAUGE', '', 'Test metric.');
END;
$$;

-- Create a metric rollup.
CALL _prom_catalog.create_rollup('test', INTERVAL '5 minutes', INTERVAL '30 days');

-- Ensure the state after rollups creation.
SELECT * from _prom_catalog.rollup;
SELECT EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ps_test');

-- Ensure the state before scanning for new rollups.
SELECT * from _prom_catalog.metric_rollup;

SELECT * FROM _prom_catalog.metric;

-- Scan and create the Caggs.
CALL _prom_catalog.scan_for_new_rollups(1, '{}'::jsonb);

SELECT * FROM _prom_catalog.metric;

-- Ensure the state after scanning for new rollups.
SELECT * from _prom_catalog.metric_rollup;

-- Delete the metric rollup.
CALL _prom_catalog.delete_rollup('test');

-- Nothing should exist.
SELECT * from _prom_catalog.rollup;
SELECT * from _prom_catalog.metric_rollup;
SELECT * FROM _prom_catalog.metric;
SELECT EXISTS(SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'ps_test');
