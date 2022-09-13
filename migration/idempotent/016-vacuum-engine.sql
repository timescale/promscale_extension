DO $block$
BEGIN
    IF _prom_catalog.is_timescaledb_installed() THEN
        CREATE OR REPLACE VIEW _ps_catalog.chunks_to_vacuum_freeze AS
        SELECT
            cc.id,
            cc.schema_name,
            cc.table_name
        FROM _timescaledb_catalog.chunk c
        INNER JOIN _timescaledb_catalog.chunk cc ON (c.dropped = false and c.compressed_chunk_id = cc.id)
        INNER JOIN pg_class k ON (k.oid = format('%I.%I', cc.schema_name, cc.table_name)::regclass::oid)
        WHERE k.relallvisible < k.relpages
        ORDER BY age(k.relfrozenxid) desc
        ;
        GRANT SELECT ON _ps_catalog.chunks_to_vacuum_freeze TO prom_reader;
        COMMENT ON VIEW _ps_catalog.chunks_to_vacuum_freeze IS 'Lists chunks that need to be vacuumed and frozen';
    END IF;
END;
$block$;
