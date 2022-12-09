CREATE TYPE _ps_catalog.signal_type
     AS ENUM ('metrics', 'traces');
GRANT USAGE ON TYPE _ps_catalog.signal_type TO prom_maintenance;

CREATE TYPE _ps_catalog.job_type
     AS ENUM ('retention', 'compression');
GRANT USAGE ON TYPE _ps_catalog.job_type TO prom_maintenance;

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
       -- delete jobs with the old config style
       PERFORM public.delete_job(job_id)
       FROM timescaledb_information.jobs
	WHERE proc_schema = '_prom_catalog' 
	  AND proc_name = 'execute_maintenance_job' 
	  AND NOT coalesce(config, '{}'::jsonb) ?& ARRAY['signal', 'type'];
       -- 2 metric retention jobs
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "retention"}');
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "retention"}');
       -- 4 metric compression jobs
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "compression"}');
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "compression"}');
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "compression"}');
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "metrics", "type": "compression"}');
       -- 1 traces retention job
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min', config=>'{"signal": "traces", "type": "retention"}');
    END IF;
END
$$;