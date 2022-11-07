CREATE OR REPLACE FUNCTION compressed_chunks_exist(_table_name TEXT) RETURNS BOOLEAN AS
$$
DECLARE
    _exists BOOLEAN;
BEGIN
    EXECUTE FORMAT($sql$
            SELECT EXISTS(
                SELECT 1 FROM _timescaledb_catalog.chunk
                    WHERE schema_name || '.' || table_name IN
                      (select show_chunks(%L)::TEXT)
                    AND compressed_chunk_id IS NOT NULL
            )
            $sql$, _table_name) INTO _exists;
    RETURN _exists;
END;
$$
LANGUAGE PLPGSQL;