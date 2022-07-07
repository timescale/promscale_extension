-- We've changed the function signature by adding new argument so dropping old one
DROP FUNCTION IF EXISTS _prom_catalog.create_ingest_temp_table(TEXT, TEXT) CASCADE;
