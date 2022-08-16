\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(1);

SELECT _prom_catalog.get_or_create_metric_table_name('cpu_usage');
CALL _prom_catalog.finalize_metric_creation();

PREPARE create_series AS SELECT _prom_catalog.create_series(
    (SELECT id FROM _prom_catalog.get_or_create_metric_table_name('cpu_usage')),
    'cpu_usage',
    ARRAY[123,234,345]);
SELECT throws_ok('create_series', 'Unable to find labels for label ids: {123,234,345}');

SELECT * FROM finish(true);