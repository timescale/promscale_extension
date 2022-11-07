\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

CREATE TABLE custom_log (
    job_id            INT,
    time              TIMESTAMP WITH TIME ZONE,
    correlation_value BIGINT,
    signal_type       _prom_ext.backend_telemetry_signal_type,
    job_type          _prom_ext.backend_telemetry_job_type,
    tags              text[]
);

CREATE OR REPLACE FUNCTION custom_func(jobid int, args jsonb) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF random() > 0.51 THEN
        PERFORM _prom_ext.push_rec(ROW(now(), 1, 'metrics', 'retention', ARRAY['']));
	    RAISE EXCEPTION 'foo';
    ELSE
	    PERFORM _prom_ext.push_rec(ROW(now(), 2, 'traces', 'compression', ARRAY['']));
    END IF;
    INSERT INTO custom_log SELECT jobid as job_id, * FROM _prom_ext.pop_recs();
EXCEPTION WHEN OTHERS THEN
    INSERT INTO custom_log SELECT jobid as job_id, * FROM _prom_ext.pop_recs();
END
$$;

SELECT * FROM plan(22);

SELECT add_job('custom_func', INTERVAL '10ms', config:='"test"'::jsonb) AS job_id;
\gset

CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);
CALL run_job(:job_id);

SELECT is(job_id, :job_id), ok(time <= now()) FROM custom_log;

SELECT ok(count(*) > 0)
FROM custom_log
WHERE correlation_value = 2 AND job_type = 'compression' AND signal_type = 'traces';

SELECT ok(count(*) > 0)
FROM custom_log
WHERE correlation_value = 1 AND job_type = 'retention' AND signal_type = 'metrics';

SELECT * FROM finish(true);