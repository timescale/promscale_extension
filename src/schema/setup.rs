use pgx::*;

// First we need to define some objects which should be defined by `promscale`
// This is mostly so that the extension can be installed standalone, which is
// convenient for development.
extension_sql!(
    r#"
--security definer function that allows setting metadata with the promscale_prefix
CREATE OR REPLACE FUNCTION @extschema@.update_tsprom_metadata(meta_key text, meta_value text, send_telemetry BOOLEAN)
RETURNS VOID
AS $func$
    INSERT INTO _timescaledb_catalog.metadata(key, value, include_in_telemetry)
    VALUES ('promscale_' || meta_key,meta_value, send_telemetry)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, include_in_telemetry = EXCLUDED.include_in_telemetry
$func$
LANGUAGE SQL VOLATILE SECURITY DEFINER;
"#,
    name = "promscale_setup"
);
