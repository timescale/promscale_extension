\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

CREATE TABLE custom_log(job_id INT, args jsonb, extra TEXT, runner NAME DEFAULT CURRENT_ROLE);

CREATE OR REPLACE FUNCTION custom_func(jobid int, args jsonb) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
	INSERT INTO custom_log VALUES($1, $2, 'normal');
	RAISE EXCEPTION 'foo';
EXCEPTION WHEN OTHERS THEN
	INSERT INTO custom_log VALUES($1, $2, 'exception');
	RAISE WARNING 'bar';
END
$$;

SELECT * FROM plan(3);


SELECT add_job('custom_func', INTERVAL '10ms', config:='"test"'::jsonb) AS job_id;
\gset

CALL run_job(:job_id);

SELECT is(job_id, :job_id), is(args, '"test"'), is(extra, 'exception') FROM custom_log LIMIT 1;

SELECT * FROM finish(true);