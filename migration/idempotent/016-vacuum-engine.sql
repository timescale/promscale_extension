DO $block$
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;

    -- https://www.postgresql.org/docs/current/storage-vm.html
    -- we cannot tell if a rel is frozen or not without an extension (pg_visible), but a page must be
    -- all visible in order to be all frozen, so if there are fewer all visible pages than there are total
    -- pages, then we know that the table must not be frozen yet and a vacuum may determine that it can be
    CREATE OR REPLACE VIEW _ps_catalog.compressed_chunks_to_freeze AS
    SELECT
        cc.id,
        cc.schema_name,
        cc.table_name,
        greatest
        (
            pg_catalog.pg_stat_get_last_vacuum_time(k.oid),
            pg_catalog.pg_stat_get_last_autovacuum_time(k.oid)
        ) as last_vacuum,
        k.relfrozenxid
    FROM _timescaledb_catalog.chunk c
    INNER JOIN _timescaledb_catalog.chunk cc
    ON (c.dropped OPERATOR(pg_catalog.=) false AND c.compressed_chunk_id OPERATOR(pg_catalog.=) cc.id)
    INNER JOIN pg_catalog.pg_class k
    ON (k.relname OPERATOR(pg_catalog.=) cc.table_name)
    INNER JOIN pg_catalog.pg_namespace n
    ON (k.relnamespace OPERATOR(pg_catalog.=) n.oid AND n.nspname OPERATOR(pg_catalog.=) cc.schema_name)
    WHERE k.relkind OPERATOR(pg_catalog.=) 'r'
    AND k.relallvisible OPERATOR(pg_catalog.<) k.relpages
    ;
    GRANT SELECT ON _ps_catalog.compressed_chunks_to_freeze TO prom_reader;
    COMMENT ON VIEW _ps_catalog.compressed_chunks_to_freeze IS 'Lists compressed chunks that need to be frozen';

    -- if a compressed chunk is missing statistics and is never later modified after initial compression
    -- then the autovacuum will completely ignore it until it passes vacuum_freeze_max_age
    -- this is not ideal. if many end up in this state, we might have great performance until a bunch of
    -- chunks hit the threshold and the autovacuum engine finally sees them and starts working them
    CREATE OR REPLACE VIEW _ps_catalog.compressed_chunks_missing_stats AS
    SELECT
        cc.id,
        cc.schema_name,
        cc.table_name,
        k.relfrozenxid
    FROM _timescaledb_catalog.chunk c
    INNER JOIN _timescaledb_catalog.chunk cc
    ON (c.dropped OPERATOR(pg_catalog.=) false AND c.compressed_chunk_id OPERATOR(pg_catalog.=) cc.id)
    INNER JOIN pg_catalog.pg_class k
    ON (k.relname OPERATOR(pg_catalog.=) cc.table_name)
    INNER JOIN pg_catalog.pg_namespace n
    ON (k.relnamespace OPERATOR(pg_catalog.=) n.oid AND n.nspname OPERATOR(pg_catalog.=) cc.schema_name)
    WHERE k.relkind OPERATOR(pg_catalog.=) 'r'
    AND k.relallvisible OPERATOR(pg_catalog.<) k.relpages
    AND pg_catalog.pg_stat_get_last_autovacuum_time(k.oid) IS NULL -- never autovacuumed
    AND pg_catalog.pg_stat_get_last_vacuum_time(k.oid) IS NULL -- never vacuumed
    AND k.reltuples > 0 -- there are tuples, but...
    AND pg_catalog.pg_stat_get_live_tuples(k.oid) = 0 -- stats appear to be missing
    ;
    GRANT SELECT ON _ps_catalog.compressed_chunks_missing_stats TO prom_reader;
    COMMENT ON VIEW _ps_catalog.compressed_chunks_missing_stats IS 'Lists compressed chunks that need to be vacuum';
END;
$block$;
