CREATE OR REPLACE FUNCTION @extschema@.label_find_key_equal(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_positive
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_positive
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.=) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.make_call_subquery_support;
ALTER FUNCTION @extschema@.label_find_key_equal(prom_api.label_key, prom_api.pattern) OWNER TO CURRENT_USER;

CREATE  OR REPLACE FUNCTION @extschema@.label_find_key_not_equal(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_negative
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_negative
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.=) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.make_call_subquery_support;
ALTER FUNCTION @extschema@.label_find_key_not_equal(prom_api.label_key, prom_api.pattern) OWNER TO CURRENT_USER;

CREATE OR REPLACE FUNCTION @extschema@.label_find_key_regex(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_positive
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_positive
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.~) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.make_call_subquery_support;
ALTER FUNCTION @extschema@.label_find_key_regex(prom_api.label_key, prom_api.pattern) OWNER TO CURRENT_USER;

CREATE OR REPLACE FUNCTION @extschema@.label_find_key_not_regex(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_negative
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_negative
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.~) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.make_call_subquery_support;
ALTER FUNCTION @extschema@.label_find_key_not_regex(prom_api.label_key, prom_api.pattern) OWNER TO CURRENT_USER;

CREATE OR REPLACE FUNCTION @extschema@.update_tsprom_metadata(meta_key text, meta_value text, send_telemetry BOOLEAN)
RETURNS VOID
SET search_path TO pg_catalog
AS $func$
    INSERT INTO _timescaledb_catalog.metadata(key, value, include_in_telemetry)
    VALUES ('promscale_' OPERATOR(pg_catalog.||) meta_key,meta_value, send_telemetry)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, include_in_telemetry = EXCLUDED.include_in_telemetry
$func$
LANGUAGE SQL VOLATILE SECURITY DEFINER;
ALTER FUNCTION @extschema@.update_tsprom_metadata(text, text, BOOLEAN) OWNER TO CURRENT_USER;