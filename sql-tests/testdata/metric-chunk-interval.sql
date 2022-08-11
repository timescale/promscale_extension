\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

CREATE OR REPLACE FUNCTION approx_is(range1 INTERVAL, range2 INTERVAL, bound NUMERIC, description TEXT)
    RETURNS TEXT AS $$
DECLARE
    result BOOLEAN;
BEGIN
    result := range1 > range2 * (1-bound) AND range1 < range2 * (1+bound);
    RETURN ok( result, description);
END
$$ LANGUAGE plpgsql;


SELECT * FROM plan(4);

SELECT is(prom_api.get_default_chunk_interval(), '8 hours'::INTERVAL, 'default metric chunk interval is 8 hours');

SELECT prom_api.set_default_chunk_interval('1 hour'::INTERVAL);

SELECT is(prom_api.get_default_chunk_interval(), '1 hour'::INTERVAL, 'default metric chunk interval is 1 hour');


SELECT _prom_catalog.get_or_create_metric_table_name('cpu_usage');
CALL _prom_catalog.finalize_metric_creation();

SELECT is(prom_api.get_metric_chunk_interval('cpu_usage'), '1 hour'::INTERVAL, 'get_metric_chunk_interval returns default chunk interval');

SELECT prom_api.set_metric_chunk_interval('cpu_usage', '15 minutes'::INTERVAL);

SELECT approx_is(prom_api.get_metric_chunk_interval('cpu_usage'), '15 minutes'::INTERVAL, 0.01, 'get_metric_chunk_interval returns chunk interval');

SELECT * FROM finish(true);
