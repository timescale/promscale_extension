TRUNCATE _ps_catalog.job_telemetry;

INSERT INTO _ps_catalog.job_telemetry (signal_type, job_type)
VALUES
     ('metrics', 'retention'),
     ('metrics', 'compression'),
     ('traces', 'retention'),
     ('traces', 'compression')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION _ps_catalog.open_job_telemetry_scope(signal_t _prom_ext.backend_telemetry_signal_type,
                                                                job_t _prom_ext.backend_telemetry_job_type)
    RETURNS _ps_catalog.job_telemetry_scope
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
  corr_id BIGINT;
BEGIN
    corr_id := pg_catalog.nextval('_ps_catalog.job_telemetry_corr_id');
    PERFORM _prom_ext.push_rec(ROW(pg_catalog.clock_timestamp(), corr_id, signal_t, job_t, ARRAY['start']));
    RETURN ROW(signal_t, job_t, corr_id);
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION 
    _ps_catalog.open_job_telemetry_scope(_prom_ext.backend_telemetry_signal_type, _prom_ext.backend_telemetry_job_type)
TO prom_admin, prom_maintenance;
COMMENT ON FUNCTION 
    _ps_catalog.open_job_telemetry_scope(_prom_ext.backend_telemetry_signal_type, _prom_ext.backend_telemetry_job_type)
IS 'TODO';
 
CREATE OR REPLACE FUNCTION _ps_catalog.close_job_telemetry_scope(scope _ps_catalog.job_telemetry_scope)
    RETURNS VOID
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
SELECT _prom_ext.push_rec(ROW(pg_catalog.clock_timestamp(), (scope).corr_id, (scope).signal_type, (scope).job_type, ARRAY['finish']));
$func$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _ps_catalog.close_job_telemetry_scope(_ps_catalog.job_telemetry_scope)
TO prom_admin, prom_maintenance;
COMMENT ON FUNCTION _ps_catalog.close_job_telemetry_scope(_ps_catalog.job_telemetry_scope)
IS 'TODO';

CREATE OR REPLACE FUNCTION _ps_catalog.update_job_telemetry()
    RETURNS VOID
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
WITH
    job_recs AS MATERIALIZED (SELECT * FROM _prom_ext.pop_recs()),
    all_starts AS (SELECT * FROM job_recs WHERE tags @> ARRAY['start']),
    all_ends AS (SELECT * FROM job_recs WHERE tags @> ARRAY['finish']),
    execution_metrics AS (
        SELECT
            s.signal_type,
            s.job_type,
            e.time - s.time AS duration,
            e.time IS NULL AS failure
        FROM all_starts s LEFT JOIN all_ends e ON s.correlation_value = e.correlation_value
    ),
    updates AS (
        SELECT signal_type,
               job_type,
               MAX(duration) AS run_duration,
               COUNT(*) FILTER (WHERE failure = true) AS new_failures,
               COUNT(*) AS new_runs
        FROM execution_metrics
        GROUP BY 1, 2
    )
UPDATE _ps_catalog.job_telemetry AS t
SET
    last_duration = run_duration,
    failures = failures + new_failures,
    total_runs = total_runs + new_runs
FROM updates AS u
WHERE u.job_type = t.job_type
  AND u.signal_type = t.signal_type;
$func$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _ps_catalog.update_job_telemetry() TO prom_admin, prom_maintenance;
COMMENT ON FUNCTION _ps_catalog.update_job_telemetry()
IS 'TODO';
