DO $block$
BEGIN
    IF _prom_catalog.is_timescaledb_installed() THEN
        CREATE OR REPLACE VIEW _ps_catalog.chunks_to_freeze AS
        SELECT
            cc.id,
            cc.schema_name,
            cc.table_name,
            greatest
            (
                pg_catalog.pg_stat_get_last_vacuum_time(k.oid),
                pg_catalog.pg_stat_get_last_autovacuum_time(k.oid)
            ) as last_vacuum,
            k.relpages,
            k.relallvisible,
            k.relfrozenxid
        FROM _timescaledb_catalog.chunk c
        INNER JOIN _timescaledb_catalog.chunk cc
        ON (c.dropped OPERATOR(pg_catalog.=) false and c.compressed_chunk_id OPERATOR(pg_catalog.=) cc.id)
        INNER JOIN pg_catalog.pg_class k
        ON (k.oid OPERATOR(pg_catalog.=) format('%I.%I', cc.schema_name, cc.table_name)::regclass::oid)
        WHERE k.relallvisible OPERATOR(pg_catalog.<) k.relpages
        ORDER BY pg_catalog.age(k.relfrozenxid) DESC
        ;
        GRANT SELECT ON _ps_catalog.chunks_to_freeze TO prom_reader;
        COMMENT ON VIEW _ps_catalog.chunks_to_freeze IS 'Lists compressed chunks that need to be frozen';
    END IF;
END;
$block$;
