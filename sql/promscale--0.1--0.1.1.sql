SET LOCAL search_path = pg_catalog;

CREATE OR REPLACE FUNCTION @extschema@.update_tsprom_metadata(meta_key text, meta_value text, send_telemetry BOOLEAN)
RETURNS VOID
SET search_path TO pg_catalog
AS $func$
    INSERT INTO _timescaledb_catalog.metadata(key, value, include_in_telemetry)
    VALUES ('promscale_' OPERATOR(pg_catalog.||) meta_key,meta_value, send_telemetry)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, include_in_telemetry = EXCLUDED.include_in_telemetry
$func$
LANGUAGE SQL VOLATILE SECURITY DEFINER;

