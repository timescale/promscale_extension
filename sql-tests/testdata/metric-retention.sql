\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(4);

SELECT is(prom_api.get_default_metric_retention_period(), '90 days'::INTERVAL, 'default metric retention period is 90 days');

SELECT _prom_catalog.get_or_create_metric_table_name('cpu_usage');
CALL _prom_catalog.finalize_metric_creation();
SELECT prom_api.set_metric_retention_period('cpu_usage', '1 day'::INTERVAL);

SELECT is(prom_api.get_metric_retention_period('cpu_usage'), '1 day'::INTERVAL, 'get_metric_retention_period returns retention period');
SELECT is(prom_api.get_metric_retention_period('prom_data', 'cpu_usage'), '1 day'::INTERVAL, 'get_metric_retention_period returns retention period');

SELECT prom_api.set_default_retention_period('55 days'::INTERVAL);

SELECT is(prom_api.get_default_metric_retention_period(), '55 days'::INTERVAL, 'get_default_metric_retention_period returns retention period');

SELECT * FROM finish(true);