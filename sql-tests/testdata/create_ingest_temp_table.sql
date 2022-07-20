\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

CREATE TEMP TABLE test_data(metric_name TEXT, prefix TEXT);

INSERT INTO test_data VALUES
  ('cpu_usage', 'exe_'),
  ('aMultiCase"fun"Metric!', 'eXe_'),
  ('aVeryLongMultiCaseMetricWhich"might"BeTruncatedIfIt''sTOOOOOOOOOOOOOOOLONGZOMG!','ThisIsLong_');

-- Note: Metric creation must be outside of the test function below, to avoid
-- 'invalid transaction termination'
SELECT _prom_catalog.get_or_create_metric_table_name(metric_name) FROM test_data;
CALL _prom_catalog.finalize_metric_creation();

CREATE OR REPLACE FUNCTION test_create_ingest_temp_table()
RETURNS SETOF TEXT LANGUAGE plpgsql AS $$
DECLARE
    metric_table_name TEXT;
    temp_table_name TEXT;
    temp_schema TEXT;
    test RECORD;
BEGIN
    FOR test IN SELECT t.metric_name, t.prefix FROM test_data t
    LOOP
        SELECT table_name INTO metric_table_name FROM _prom_catalog.get_or_create_metric_table_name(test.metric_name);

        RETURN NEXT has_table('prom_data', metric_table_name, format('table %I.%I exists', 'prom_data', metric_table_name));

        SELECT _prom_catalog.create_ingest_temp_table(metric_table_name, 'prom_data', test.prefix) INTO temp_table_name;
        RETURN NEXT is(temp_table_name, left(test.prefix || metric_table_name, 62) , 'temp table name is well-formed');
        SELECT nspname INTO temp_schema FROM pg_namespace WHERE oid = pg_my_temp_schema();
        RETURN NEXT has_table(temp_schema, temp_table_name, format('temp table %I exists', temp_table_name));
    END LOOP;
END;
$$;

SELECT * FROM runtests('test_create_ingest_temp_table');

