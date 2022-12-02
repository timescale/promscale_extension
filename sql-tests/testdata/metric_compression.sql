\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

\set older_than '1 hour'

select * from plan(11);

-- we don't want the maintenance job run automatically during this test
select delete_job(job_id)
from timescaledb_information.jobs
where proc_name = 'execute_maintenance_job'
;

-- create a metric named cpu_usage
select _prom_catalog.get_or_create_metric_table_name('cpu_usage');
call _prom_catalog.finalize_metric_creation();
select prom_api.set_metric_retention_period('cpu_usage', '100 years'::interval);
select prom_api.set_metric_chunk_interval('cpu_usage', '1 day'::interval);

-- create a series for the cpu_usage metric. put series_id into :series_id variable
select x.series_id
from _prom_catalog.get_or_create_series_id_for_kv_array(
'cpu_usage',
array['__name__', 'test'],
array['cpu_usage', 'value1']
) x
\gset

-- create 1 old chunk
insert into prom_data.cpu_usage(time, value, series_id)
values ('1982-01-01 00:00:00+00', 0.1, :series_id)
;

-- 1
select ok(count(*) = 1, 'expect cpu_usage to have 1 chunk')
from public.show_chunks('prom_data.cpu_usage'::regclass)
;

-- 2
select ok(count(*) = 0, 'expect no chunks to compress b/c we do not compress the most recent chunk')
from _prom_catalog.metric_chunks_that_need_to_be_compressed(interval :'older_than') x
where metric_name = 'cpu_usage'
;

-- this should do nothing
call _prom_catalog.execute_compression_policy(log_verbose=>true);

-- 3
select ok(count(*) = 0, 'expect no chunks to compress b/c we do not compress the most recent chunk')
from _prom_catalog.metric_chunks_that_need_to_be_compressed(interval :'older_than') x
where metric_name = 'cpu_usage'
;

-- create a second old chunk
insert into prom_data.cpu_usage(time, value, series_id)
values ('1982-02-01 00:00:00+00', 0.1, :series_id)
;

-- 4
select ok(count(*) = 2, 'expect cpu_usage to have 2 chunks')
from public.show_chunks('prom_data.cpu_usage'::regclass)
;

-- 5
select ok(jsonb_array_length(x.chunks_to_compress) = 1, 'expect 1 chunk to compress')
from _prom_catalog.metric_chunks_that_need_to_be_compressed(interval :'older_than') x
where metric_name = 'cpu_usage'
;

-- this should compress 1 chunk
call _prom_catalog.execute_compression_policy(log_verbose=>true);

-- 6
select ok(count(*) = 2, 'expect cpu_usage to have 2 chunks')
from public.show_chunks('prom_data.cpu_usage'::regclass)
;

-- 7
select ok(count(*) = 0, 'expect cpu_usage metric to have NO chunks to compress')
from _prom_catalog.metric_chunks_that_need_to_be_compressed(interval :'older_than') x
where metric_name = 'cpu_usage'
;

-- create a two more old chunks
insert into prom_data.cpu_usage(time, value, series_id)
values
('1982-03-01 00:00:00+00', 0.1, :series_id),
('1982-04-01 00:00:00+00', 0.1, :series_id)
;

-- 8
select ok(count(*) = 4, 'expect cpu_usage to have 4 chunks')
from public.show_chunks('prom_data.cpu_usage'::regclass)
;

-- 9
select ok(jsonb_array_length(x.chunks_to_compress) = 2, 'expect 2 chunks to compress')
from _prom_catalog.metric_chunks_that_need_to_be_compressed(interval :'older_than') x
where metric_name = 'cpu_usage'
;

-- this should compress 2 chunks
call _prom_catalog.execute_compression_policy(log_verbose=>true);

-- 10
select ok(count(*) = 4, 'expect cpu_usage to have 4 chunks')
from public.show_chunks('prom_data.cpu_usage'::regclass)
;

-- 11
select ok(count(*) = 0, 'expect cpu_usage metric to have NO chunks to compress')
from _prom_catalog.metric_chunks_that_need_to_be_compressed(interval :'older_than') x
where metric_name = 'cpu_usage'
;

select * from finish(true);
