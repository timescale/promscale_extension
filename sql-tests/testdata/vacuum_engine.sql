\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

select * from plan(6);

-- create one hypertable
create table metric1(id int, t timestamptz not null, val double precision) with (autovacuum_enabled = 'off');
select create_hypertable('metric1'::regclass, 't', chunk_time_interval=>'5 minutes'::interval);
alter table metric1 set (timescaledb.compress, timescaledb.compress_segmentby = 'id');
select 1 as add_compression_policy from add_compression_policy('metric1', INTERVAL '7 days');

-- load it with data
select format($$insert into metric1 (id, t, val) values (%L, %L, %L)$$
, id
, 'today'::timestamptz + (t * '5 minutes'::interval)
, random()
)
from generate_series(1, 10) id
cross join generate_series(1, 50) t
\gexec

-- create a second hypertable
create table metric2(id int, t timestamptz not null, val double precision) with (autovacuum_enabled = 'off');
select create_hypertable('metric2'::regclass, 't', chunk_time_interval=>'5 minutes'::interval);
alter table metric2 set (timescaledb.compress, timescaledb.compress_segmentby = 'id');
select 1 as add_compression_policy from add_compression_policy('metric2', INTERVAL '7 days');

-- load it with data
select format($$insert into metric2 (id, t, val) values (%L, %L, %L)$$
, id
, 'today'::timestamptz + (t * '5 minutes'::interval)
, random()
)
from generate_series(1, 10) id
cross join generate_series(1, 50) t
\gexec

-- make sure we got some chunks out of the endeavor
select isnt_empty(
    'select * from _timescaledb_catalog.chunk',
    'chunks were created'
);

-- there ought not be any results from the view because no chunks are compressed
select is_empty(
    'select * from _ps_catalog.compressed_chunks_to_freeze',
    'zero results when no chunks compressed'
);

-- disable autovacuum on the compressed hypertable too so the compressed chunks won't
-- get vacuumed automatically either
select format($$alter table %I.%I set (autovacuum_enabled = 'off')$$, ch.schema_name, ch.table_name)
from _timescaledb_catalog.hypertable h
inner join _timescaledb_catalog.hypertable ch on (h.compressed_hypertable_id = ch.id)
and h.schema_name = 'public' and h.table_name in ('metric1', 'metric2')
\gexec


create temp table _chosen_uncompressed_chunks (id int, schema_name text, table_name text);
create temp table _chosen_compressed_chunks (id int, schema_name text, table_name text);

-- pick 15 random uncompressed chunks and compress them
insert into pg_temp._chosen_uncompressed_chunks (id, schema_name, table_name)
select id, schema_name, table_name
from _timescaledb_catalog.chunk k
where compressed_chunk_id is null
and table_name not like 'compress_%'
order by random()
limit 15
;

-- make sure we got 15
select results_eq(
    'select count(*) from pg_temp._chosen_uncompressed_chunks',
    array[15::bigint],
    '15 uncompressed chunks should have been chosen'
);

-- compress the chosen chunks
do $block$
declare
    _sql text;
begin
    for _sql in
    (
        select format('select compress_chunk(%L::regclass)', format('%s.%s', schema_name, table_name))
        from pg_temp._chosen_uncompressed_chunks
        order by id
    )
    loop
        execute _sql;
    end loop;
end;
$block$;

-- find the chunks we compressed
insert into _chosen_compressed_chunks (id, schema_name, table_name)
select cc.id, cc.schema_name, cc.table_name
from _chosen_uncompressed_chunks x
inner join _timescaledb_catalog.chunk c on (x.id = c.id)
inner join _timescaledb_catalog.chunk cc on (c.compressed_chunk_id = cc.id)
;

-- make sure we got 15
select results_eq(
    'select count(*) from pg_temp._chosen_compressed_chunks',
    array[15::bigint],
    '15 compressed chunks should have been created'
);

-- view should return the 15 chosen compressed chunks
select results_eq(
    'select id from _ps_catalog.compressed_chunks_to_freeze order by id',
    'select id from pg_temp._chosen_compressed_chunks order by id',
    'view should return the 15 chosen compressed chunks'
);

select lives_ok(
    'select * from _ps_catalog.compressed_chunks_missing_stats',
    'compressed_chunks_missing_stats view works'
);

/*
here we *could* vacuum (freeze, analyze) each of the compressed chunks
and see whether they disappear from the view
unfortunately, it appears that the relallvisible column is not updated
transactionally or immediately with the vacuum
so it becomes a matter of pg_sleeping an indeterminate amount of time
and hoping that the column has been updated by the time we check the view
this leads to extremely flaky tests and much wailing and gnashing of teeth
so, regretfully, we are not doing that here
*/

select * from finish(true);
