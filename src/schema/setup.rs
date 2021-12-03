use pgx::*;

// First we need to define some objects which should be defined by `promscale`
// This is mostly so that the extension can be installed standalone, which is
// convenient for development.
extension_sql!(
    r#"
CREATE OR REPLACE FUNCTION @extschema@.swallow_error(query text) RETURNS VOID AS
$$
BEGIN
    BEGIN
        EXECUTE query;
    EXCEPTION WHEN duplicate_object THEN
        RAISE NOTICE 'object already exists, skipping create';
    END;
END;
$$
LANGUAGE PLPGSQL;

SELECT swallow_error('CREATE ROLE prom_reader;');
SELECT swallow_error('CREATE DOMAIN @extschema@.matcher_positive AS int[] NOT NULL;');
SELECT swallow_error('CREATE DOMAIN @extschema@.matcher_negative AS int[] NOT NULL;');
SELECT swallow_error('CREATE DOMAIN @extschema@.label_key AS TEXT NOT NULL;');
SELECT swallow_error('CREATE DOMAIN @extschema@.pattern AS TEXT NOT NULL;');

DROP FUNCTION @extschema@.swallow_error(text);

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
