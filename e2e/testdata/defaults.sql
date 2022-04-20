\set ECHO all
\set ON_ERROR_STOP 1
create extension promscale;

\echo make sure the view returns what we expect it to
select key, value
from _prom_catalog.default_default dd
union
select key, value
from
(
    values
    ('chunk_interval'           , (INTERVAL '8 hours')::text),
    ('retention_period'         , (90 * INTERVAL '1 day')::text),
    ('metric_compression'       , (exists(select 1 from pg_catalog.pg_proc where proname = 'compress_chunk')::text)),
    ('trace_retention_period'   , (30 * INTERVAL '1 days')::text),
    ('ha_lease_timeout'         , '1m'),
    ('ha_lease_refresh'         , '10s')
) x(key, value)
;

\echo make sure the getter returns the expected value
select _prom_catalog.get_default_value('chunk_interval') = (INTERVAL '8 hours')::text;

\echo setting the default value to the same as the default default should be a noop
select _prom_catalog.set_default_value('chunk_interval', (INTERVAL '8 hours')::text);
select count(*) = 0 from _prom_catalog.default d where d.key = 'chunk_interval';

\echo overriding the default default should land a new row in the default table
select _prom_catalog.set_default_value('chunk_interval', (INTERVAL '99 hours')::text);
select count(*) = 1 from _prom_catalog.default d where d.key = 'chunk_interval';
\echo make sure the getter returns the new value
select _prom_catalog.get_default_value('chunk_interval') = (INTERVAL '99 hours')::text;

\echo setting the default value BACK to the same as the default default should remove the row from the default table
select _prom_catalog.set_default_value('chunk_interval', (INTERVAL '8 hours')::text);
select count(*) = 0 from _prom_catalog.default d where d.key = 'chunk_interval';
