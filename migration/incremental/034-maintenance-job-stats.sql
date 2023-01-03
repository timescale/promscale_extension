CREATE TYPE _ps_catalog.signal_type
     AS ENUM ('metrics', 'traces');
GRANT USAGE ON TYPE _ps_catalog.signal_type TO prom_maintenance;

CREATE TYPE _ps_catalog.job_type
     AS ENUM ('retention', 'compression');
GRANT USAGE ON TYPE _ps_catalog.job_type TO prom_maintenance;

-- Copy-pasted from idempotent
CREATE FUNCTION _prom_catalog.add_job(proc regproc, schedule_interval interval, config jsonb = NULL) 
    RETURNS INTEGER 
    --security definer to add jobs as the logged-in user
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND _prom_catalog.get_timescale_minor_version() >= 9
    THEN
        RETURN 
            public.add_job(
                proc, 
                schedule_interval, 
                config=>config,
                -- shift the inital start time to avoid a thundering herd
                -- now + random[schedule_interval / 2; schedule_interval]
                initial_start=>now() + (random() / 2.0 + 0.5) * schedule_interval,
                fixed_schedule=>false
            );
    ELSE
        RETURN 
            public.add_job(
                proc, 
                schedule_interval, 
                config=>config,
                -- shift the inital start time to avoid a thundering herd
                -- now + random[schedule_interval / 2; schedule_interval]
                initial_start=>now() + (random() / 2.0 + 0.5) * schedule_interval
                -- fixed schedule didn't exist prior to TS 2.9
            );
    END IF;
END
$func$
LANGUAGE PLPGSQL;
REVOKE ALL ON FUNCTION _prom_catalog.add_job(regproc, interval, jsonb) FROM public;

--add jobs for each workload executing every 30 min by default 
DO $$
DECLARE
    _is_restore_in_progress boolean = false;
BEGIN
    _is_restore_in_progress = coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND NOT _is_restore_in_progress
        THEN
       -- migrate the execute_maintenance_job
       -- delete jobs with the old config style
       PERFORM public.delete_job(job_id)
       FROM timescaledb_information.jobs
        WHERE proc_schema = '_prom_catalog' 
        AND proc_name = 'execute_maintenance_job' 
        AND NOT coalesce(config, '{}'::jsonb) ?& ARRAY['signal', 'type'];
       -- 2 metric retention jobs
       PERFORM _prom_catalog.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "retention"}');
       PERFORM _prom_catalog.add_job('_prom_catalog.execute_maintenance_job', '31 min', config=>'{"signal": "metrics", "type": "retention"}');
       -- 3 metric compression jobs
       PERFORM _prom_catalog.add_job('_prom_catalog.execute_maintenance_job', '29 min', config=>'{"signal": "metrics", "type": "compression"}');
       PERFORM _prom_catalog.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "compression"}');
       PERFORM _prom_catalog.add_job('_prom_catalog.execute_maintenance_job', '31 min', config=>'{"signal": "metrics", "type": "compression"}');
       -- 1 traces retention job
       PERFORM _prom_catalog.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "traces", "type": "retention"}');

       -- migrate the execute_tracing_compression_job, their config didn't change, but the add_job itself did.
       -- delete jobs with the old config style
       PERFORM public.delete_job(job_id)
       FROM timescaledb_information.jobs
        WHERE proc_schema = '_ps_trace' 
        AND proc_name = 'execute_tracing_compression_job';
       -- re-introduce the jobs
       PERFORM _prom_catalog.add_job('_ps_trace.execute_tracing_compression_job', '1 hour', config=>'{"log_verbose":false,"hypertable_name":"span"}');
       PERFORM _prom_catalog.add_job('_ps_trace.execute_tracing_compression_job', '1 hour', config=>'{"log_verbose":false,"hypertable_name":"event"}');
       PERFORM _prom_catalog.add_job('_ps_trace.execute_tracing_compression_job', '1 hour', config=>'{"log_verbose":false,"hypertable_name":"link"}');
    END IF;
END
$$;