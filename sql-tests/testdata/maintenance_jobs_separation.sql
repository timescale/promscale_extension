\unset ECHO
\set QUIET 1
\set ON_ERROR_STOP 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

-- Make sure backwards compatible call works
CALL prom_api.execute_maintenance();

-- None of the new maintenance job configurations fail to parse or start
CALL _prom_catalog.execute_maintenance_job(0, '{"signal": "metrics", "type": "retention"}'::jsonb);
CALL _prom_catalog.execute_maintenance_job(0, '{"signal": "traces", "type": "retention"}'::jsonb);
CALL _prom_catalog.execute_maintenance_job(0, '{"signal": "metrics", "type": "compression"}'::jsonb);


SELECT * FROM plan(5);

-- No old-style configurations are present at the beginning
SELECT ok(COUNT(*) = 0) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog' 
  AND NOT coalesce(config, '{}'::jsonb) ?& ARRAY ['signal', 'type'];

-- Add two old-style configurations
SELECT public.add_job('_prom_catalog.execute_maintenance_job', '30 min');
SELECT public.add_job('_prom_catalog.execute_maintenance_job', '30 min');

-- Run config maintenance reconfiguration
SELECT prom_api.config_maintenance_jobs(1, '10 min');

-- Only the new-style configurations should be present
SELECT ok(COUNT(*) = 0) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog' 
  AND NOT coalesce(config, '{}'::jsonb) ?& ARRAY ['signal', 'type'];

SELECT ok(COUNT(*) = 3) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog';

-- Increase the number of jobs
SELECT prom_api.config_maintenance_jobs(2, '15 min', '{"log_verbose": false}');

SELECT ok(COUNT(*) = 6) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND coalesce(config, '{}'::jsonb) ?& ARRAY ['signal', 'type'];

-- Decrease the number of jobs
SELECT prom_api.config_maintenance_jobs(1, '15 min', '{"log_verbose": false}');

SELECT ok(COUNT(*) = 3) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND coalesce(config, '{}'::jsonb) ?& ARRAY ['signal', 'type'];

SELECT * FROM finish(true);