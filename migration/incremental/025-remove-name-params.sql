
-- changing these functions to use text data types for parameters and return values instead of name
-- name can have collation related planner issues
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_local_size(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_node_up(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_compression_stats_for_schema(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_remote_size(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.metric_view() CASCADE;
