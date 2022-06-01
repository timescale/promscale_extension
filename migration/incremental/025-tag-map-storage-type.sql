-- We have to mutate the catalog for two reasons:
-- 1. ALTER TYPE tag_map SET (STORAGE = EXTENDED); is not supported on PG12
-- 2. We can not ALTER hypertables that have compression enabled.

-- tag_v
-- This statement can become ALTER TYPE once we drop pg12 support
UPDATE pg_catalog.pg_type AS t 
SET typstorage = 'x' 
WHERE t.oid = '_ps_trace.tag_v'::regtype::oid;

-- This statement can become ALTER TABLE once Timescale allows altering compressed tables.
UPDATE pg_catalog.pg_attribute AS a
SET attstorage = 'x'
WHERE a.attrelid = '_ps_trace.tag'::regclass::oid
  AND a.atttypid = '_ps_trace.tag_v'::regtype::oid;

-- tag_map
-- This statement can become ALTER TYPE once we drop pg12 support
UPDATE pg_catalog.pg_type AS t 
SET typstorage = 'x' 
WHERE t.oid = 'ps_trace.tag_map'::regtype::oid;

-- This statement can become ALTER TABLE once Timescale allows altering compressed tables.
UPDATE pg_catalog.pg_attribute AS a
SET attstorage = 'x'
WHERE a.attrelid  IN ('_ps_trace.span'::regclass::oid, '_ps_trace.event'::regclass::oid, '_ps_trace.link'::regclass::oid)
  AND a.atttypid = 'ps_trace.tag_map'::regtype::oid;