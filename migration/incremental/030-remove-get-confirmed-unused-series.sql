-- renaming an argument, so we have to drop the prev version first
DROP FUNCTION IF EXISTS _prom_catalog.get_confirmed_unused_series(TEXT, TEXT, TEXT, BIGINT[], TIMESTAMPTZ);
