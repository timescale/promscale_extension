\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(8);

/*
    create two hypertables and load them with enough data to create a couple thousand chunks
    enable compression on the hypertables
    but set the interval high enough that compression doesn't happen automatically
    we will compress a few, and see if they show up in the view
    then, we'll vacuum freeze them and make sure they disappear from the view
    rinse repeat
*/

-- create one hypertable
create table metric1(id int, t timestamptz not null, val double precision);
select create_hypertable('metric1'::regclass, 't', chunk_time_interval=>'5 minutes'::interval);
alter table metric1 set (timescaledb.compress, timescaledb.compress_segmentby = 'id');
select add_compression_policy('metric1', INTERVAL '7 days');

-- load it with data
select format($$insert into metric1 (id, t, val) values (%L, %L, %L)$$
, id
, 'today'::timestamptz + (t * '5 minutes'::interval)
, random()
)
from generate_series(1, 10) id
cross join generate_series(1, 1000) t
\gexec

-- create a second hypertable
create table metric2(id int, t timestamptz not null, val double precision);
select create_hypertable('metric2'::regclass, 't', chunk_time_interval=>'5 minutes'::interval);
alter table metric2 set (timescaledb.compress, timescaledb.compress_segmentby = 'id');
select add_compression_policy('metric2', INTERVAL '7 days');

-- load it with data
select format($$insert into metric2 (id, t, val) values (%L, %L, %L)$$
, id
, 'today'::timestamptz + (t * '5 minutes'::interval)
, random()
)
from generate_series(1, 10) id
cross join generate_series(1, 1000) t
\gexec

-- make sure we got some chunks out of the endeavor
select isnt_empty('select * from _timescaledb_catalog.chunk', 'chunks were created');

-- there ought not be any results from the view because no chunks are compressed
select is_empty('select * from _ps_catalog.chunks_to_vacuum_freeze', 'zero results when no chunks compressed');

create temp table _chosen_uncompressed_chunks (id int, schema_name text, table_name text);
create temp table _chosen_compressed_chunks (id int, schema_name text, table_name text);

-- pick 5 random uncompressed chunks
insert into pg_temp._chosen_uncompressed_chunks (id, schema_name, table_name)
select id, schema_name, table_name
from _timescaledb_catalog.chunk k
where compressed_chunk_id is null
order by random()
limit 5
;
select results_eq(
    'select count(*) from pg_temp._chosen_uncompressed_chunks',
    array[5::bigint],
    '5 uncompressed chunks should have been chosen'
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


insert into _chosen_compressed_chunks (id, schema_name, table_name)
select cc.id, cc.schema_name, cc.table_name
from _chosen_uncompressed_chunks x
inner join _timescaledb_catalog.chunk c on (x.id = c.id)
inner join _timescaledb_catalog.chunk cc on (c.compressed_chunk_id = cc.id)
;

-- view should return the 5 chosen compressed chunks
select results_eq(
    'select compressed_chunk_id from _ps_catalog.chunks_to_vacuum_freeze order by compressed_chunk_id',
    'select id from pg_temp._chosen_compressed_chunks order by id',
    'view should return the 5 chosen compressed chunks'
);

-- vacuum freeze the chosen
select format('vacuum (freeze, analyze) %I.%I', schema_name, table_name)
from pg_temp._chosen_compressed_chunks
\gexec

select is_empty('select * from _ps_catalog.chunks_to_vacuum_freeze', 'zero results after chunks were frozen');

-- reset and do it again ------------------------------------------------------
truncate _chosen_uncompressed_chunks;
truncate _chosen_compressed_chunks;
-------------------------------------------------------------------------------

-- pick 5 random uncompressed chunks
insert into pg_temp._chosen_uncompressed_chunks (id, schema_name, table_name)
select id, schema_name, table_name
from _timescaledb_catalog.chunk k
where compressed_chunk_id is null
order by random()
limit 5
;
select results_eq(
    'select count(*) from pg_temp._chosen_uncompressed_chunks',
    array[5::bigint],
    '5 uncompressed chunks should have been chosen'
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


insert into _chosen_compressed_chunks (id, schema_name, table_name)
select cc.id, cc.schema_name, cc.table_name
from _chosen_uncompressed_chunks x
inner join _timescaledb_catalog.chunk c on (x.id = c.id)
inner join _timescaledb_catalog.chunk cc on (c.compressed_chunk_id = cc.id)
;

-- view should return the 5 chosen compressed chunks
select results_eq(
    'select compressed_chunk_id from _ps_catalog.chunks_to_vacuum_freeze order by compressed_chunk_id',
    'select id from pg_temp._chosen_compressed_chunks order by id',
    'view should return the 5 chosen compressed chunks'
);

-- vacuum freeze the chosen
select format('vacuum (freeze, analyze) %I.%I', schema_name, table_name)
from pg_temp._chosen_compressed_chunks
\gexec

select is_empty('select * from _ps_catalog.chunks_to_vacuum_freeze', 'zero results after chunks were frozen');

SELECT * FROM finish(true);
