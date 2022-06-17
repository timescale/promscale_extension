-- When we changed the storage type of `ps_trace.tag_map` and
-- `_ps_trace.tag_v` from `PLAIN` to `EXTENDED`, we didn't update all
-- `pg_attribute` entries. This meant that the definitions for our views
-- (`ps_trace.{event,link,span}`) were incorrect.
--
-- While we noticed this specifically with our views, it could also cascade
-- to relations which end users built on top of our types.
UPDATE pg_catalog.pg_attribute AS a
SET attstorage = 'x'
WHERE a.atttypid = '_ps_trace.tag_v'::regtype::oid;

UPDATE pg_catalog.pg_attribute AS a
SET attstorage = 'x'
WHERE a.atttypid = 'ps_trace.tag_map'::regtype::oid;
