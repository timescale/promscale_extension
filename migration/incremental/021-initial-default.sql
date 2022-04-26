
DELETE FROM _prom_catalog.default x
WHERE x.key IN
(
    SELECT d.key
    FROM _prom_catalog.default d
    LEFT OUTER JOIN
    (
        -- the view won't exists yet since it's in the idempotent
        -- so use a values clause
        VALUES
        ('chunk_interval'           , (INTERVAL '8 hours')::text),
        ('retention_period'         , (90 * INTERVAL '1 day')::text),
        ('metric_compression'       , (exists(select 1 from pg_catalog.pg_proc where proname = 'compress_chunk')::text)),
        ('trace_retention_period'   , (30 * INTERVAL '1 days')::text),
        ('ha_lease_timeout'         , '1m'),
        ('ha_lease_refresh'         , '10s')
    ) dd(key, value) ON (d.key = dd.key)
    WHERE d.value is not distinct from dd.value
);
