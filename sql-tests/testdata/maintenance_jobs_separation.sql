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


SELECT * FROM plan(9);

-- No old-style configurations are present at the beginning
SELECT ok(COUNT(*) = 0, 'No old-style configurations are present at the beginning') 
FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog' 
  AND NOT coalesce(config, '{}'::jsonb) ?& ARRAY ['signal', 'type'];

SELECT ok(COUNT(*) = 2, 'Two metrics retention jobs by default.')
FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND config ->> 'signal' = 'metrics' 
  AND config ->> 'type' = 'retention';

SELECT ok(COUNT(*) = 3, 'Three metrics compression jobs by default.')
FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND config ->> 'signal' = 'metrics' 
  AND config ->> 'type' = 'compression';

SELECT ok(COUNT(*) = 1, 'And one traces retention job by default.')
FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND config ->> 'signal' = 'traces' 
  AND config ->> 'type' = 'retention';

-- Add two old-style configurations
SELECT public.add_job('_prom_catalog.execute_maintenance_job', '30 min');
SELECT public.add_job('_prom_catalog.execute_maintenance_job', '30 min');

-- Run config maintenance reconfiguration
SELECT prom_api.config_maintenance_jobs(1, '10 min');

SELECT ok(COUNT(*) = 0, 'Old-style config jobs should be deleted by config_maintenance_jobs')
FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog' 
  AND NOT coalesce(config, '{}'::jsonb) ?& ARRAY ['signal', 'type'];

SELECT ok(COUNT(*) = 3, 'Only the new-style configurations should be present')
FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND (schedule_interval >= '10 min' OR schedule_interval < '15 min');

-- Increase the number of jobs
SELECT prom_api.config_maintenance_jobs(2, '15 min', '{"log_verbose": true}');

SELECT ok(COUNT(*) = 6) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND config ?& ARRAY ['signal', 'type']
  AND (schedule_interval >= '15 min' OR schedule_interval < '17 min')
  AND coalesce(config ->> 'log_verbose', 'false')::boolean = true;

-- Decrease the number of jobs
SELECT prom_api.config_maintenance_jobs(1, '16 min', '{"log_verbose": false}');

SELECT ok(COUNT(*) = 3) FROM timescaledb_information.jobs 
WHERE proc_schema = '_prom_catalog'
  AND config ?& ARRAY ['signal', 'type']
  AND (schedule_interval >= '16 min' OR schedule_interval < '18 min')
  AND coalesce(config ->> 'log_verbose', 'true')::boolean = false;

SELECT throws_like(
	$$SELECT prom_api.config_maintenance_jobs(1, '100 min', '{"log_verbose": "err"}')$$,
	'invalid input syntax for type boolean: "err"'
	);

SELECT * FROM finish(true);