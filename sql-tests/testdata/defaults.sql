\set ECHO all
\set ON_ERROR_STOP 1

\echo make sure the view returns what we expect it to
select key, value
from _prom_catalog.initial_default dd
except
select key, value
from
(
    values
    ('chunk_interval'           , (INTERVAL '8 hours')::text),
    ('retention_period'         , (90 * INTERVAL '1 day')::text),
    ('metric_compression'       , (exists(select 1 from pg_catalog.pg_proc where proname = 'compress_chunk')::text)),
    ('trace_retention_period'   , (30 * INTERVAL '1 days')::text),
    ('ha_lease_timeout'         , '1m'),
    ('ha_lease_refresh'         , '10s'),
    ('epoch_duration'           , (INTERVAL '12 hours')::text),
    ('downsample'               , 'false'),
    ('downsample_old_data'      , 'false')
) x(key, value)
;

\echo make sure the getter returns the expected value
select _prom_catalog.get_default_value('chunk_interval') = (INTERVAL '8 hours')::text;
select count(*) = 0 from _prom_catalog.default d where d.key = 'chunk_interval';

\echo setting the default value to the same as the initial default
select _prom_catalog.set_default_value('chunk_interval', (INTERVAL '8 hours')::text);
select count(*) = 1 from _prom_catalog.default d where d.key = 'chunk_interval';
select _prom_catalog.get_default_value('chunk_interval') = (INTERVAL '8 hours')::text;

\echo overriding the initial default
select _prom_catalog.set_default_value('chunk_interval', (INTERVAL '99 hours')::text);
select count(*) = 1 from _prom_catalog.default d where d.key = 'chunk_interval';
select _prom_catalog.get_default_value('chunk_interval') = (INTERVAL '99 hours')::text;

\echo setting the default value BACK to the same as the initial default
select _prom_catalog.set_default_value('chunk_interval', (INTERVAL '8 hours')::text);
select count(*) = 1 from _prom_catalog.default d where d.key = 'chunk_interval';
select _prom_catalog.get_default_value('chunk_interval') = (INTERVAL '8 hours')::text;
