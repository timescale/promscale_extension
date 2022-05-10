CREATE OR REPLACE PROCEDURE _ps_trace.execute_tracing_compression(hypertable_name name, log_verbose BOOLEAN = false)
AS $$
DECLARE
   startT TIMESTAMPTZ;
BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;

    startT := clock_timestamp();

    PERFORM _prom_catalog.set_app_name(format('promscale tracing compression: %s', hypertable_name));
    IF log_verbose THEN
        RAISE LOG 'promscale tracing compression starting';
    END IF;

    CALL _prom_catalog.compress_old_chunks('_ps_trace', hypertable_name, now() - INTERVAL '1 hour');

    IF log_verbose THEN
        RAISE LOG 'promscale tracing compression: %s finished in %', hypertable_name, clock_timestamp()-startT;
    END IF;
END;
$$ LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _ps_trace.execute_tracing_compression(name, boolean)
IS 'Execute tracing compression compresses tracing tables';
GRANT EXECUTE ON PROCEDURE _ps_trace.execute_tracing_compression(name, boolean) TO prom_maintenance;

--job boilerplate
CREATE OR REPLACE PROCEDURE _ps_trace.execute_tracing_compression_job(job_id int, config jsonb)
AS $$
DECLARE
   log_verbose boolean;
   ae_key text;
   ae_value text;
   ae_load boolean := FALSE;
BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;
    log_verbose := coalesce(config->>'log_verbose', 'false')::boolean;
    hypertable_name := config->>'hypertable_name';

    --if auto_explain enabled in config, turn it on in a best-effort way
    --i.e. if it fails (most likely due to lack of superuser priviliges) move on anyway.
    BEGIN
        FOR ae_key, ae_value IN
           SELECT * FROM jsonb_each_text(config->'auto_explain')
        LOOP
            IF NOT ae_load THEN
                ae_load := true;
                LOAD 'auto_explain';
            END IF;

            PERFORM set_config('auto_explain.'|| ae_key, ae_value, FALSE);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'could not set auto_explain options';
    END;


    CALL _ps_trace.execute_tracing_compression(hypertable_name, log_verbose=>log_verbose);
END
$$ LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _ps_trace.execute_tracing_compression_job(int, jsonb) TO prom_maintenance;