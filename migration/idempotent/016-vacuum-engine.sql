DO $block$
BEGIN
    IF _prom_catalog.is_timescaledb_installed() THEN
        CREATE OR REPLACE VIEW _ps_catalog.chunks_to_vacuum_freeze AS
        SELECT
            c.hypertable_id,
            c.id as chunk_id,
            cc.id as compressed_chunk_id,
            cc.schema_name,
            cc.table_name,
            t.vacuum_count,
            t.autovacuum_count,
            t.last_vacuum,
            t.last_autovacuum,
            k.relallvisible
        FROM _timescaledb_catalog.chunk c
        INNER JOIN _timescaledb_catalog.chunk cc ON (c.dropped = false and c.compressed_chunk_id = cc.id)
        INNER JOIN
        (
            SELECT
              d.id,
              d.hypertable_id,
              row_number() OVER (PARTITION BY d.hypertable_id ORDER BY d.id) as dimension_nbr
            FROM _timescaledb_catalog.dimension d
        ) d ON (c.hypertable_id = d.hypertable_id and d.dimension_nbr = 1)
        INNER JOIN _timescaledb_catalog.dimension_slice ds on (d.id = ds.dimension_id)
        INNER JOIN _timescaledb_catalog.chunk_constraint con on (ds.id = con.dimension_slice_id and con.chunk_id = c.id)
        INNER JOIN pg_class k ON (k.oid = format('%I.%I', cc.schema_name, cc.table_name)::regclass::oid)
        INNER JOIN pg_stat_all_tables t ON (t.relid = k.oid)
        WHERE k.relallvisible = 0 -- not already fully frozen
        ORDER BY
            greatest(t.vacuum_count, t.autovacuum_count), -- chunks vacuumed fewest times first
            greatest(t.last_vacuum, t.last_autovacuum) NULLS FIRST, -- chunks never vacuumed first followed by ones vacuumed furthest in the past
            ds.range_start -- chunks that represent older data first
        ;
        GRANT SELECT ON _ps_catalog.chunks_to_vacuum_freeze TO prom_reader;
        COMMENT ON VIEW _ps_catalog.chunks_to_vacuum_freeze IS 'Lists chunks that need to be vacuumed and frozen';
    END IF;
END;
$block$;
