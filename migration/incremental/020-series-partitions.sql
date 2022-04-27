DO $block$
DECLARE
    _missing boolean = false;
    _cmds json;
    _cmd text;
BEGIN

    /*
    We need to drop the _prom_catalog.series_deleted and _prom_catalog.series_labels_id
    indexes. They are defined on the _prom_catalog.series table which is partitioned. We
    don't want the index defined on the parent. We want it defined on each child individually
    manually. Having it defined on the parent causes the indexes to be defined automatically
    on the partitions which causes issues with the dump/restore process.
    If we just drop the indexes from the parent table, it will cause the indexes to be dropped
    from the children too. Then, we would need to recreate them, which could be extremely slow.
    Instead, we will detach the partitions from the parent, drop the indexes from the parent
    (which preserves the indexes on the children, and then reattach the partitions to the parent.
    */

    -- skip if neither index exists
    SELECT count(*) = 0 INTO STRICT _missing
    FROM pg_class t
    INNER JOIN pg_index i ON (t.oid = i.indrelid)
    INNER JOIN pg_class x ON (i.indexrelid = x.oid)
    INNER JOIN pg_namespace n ON (t.relnamespace = n.oid)
    WHERE t.relname = 'series'
    AND n.nspname = '_prom_catalog'
    AND x.relname in ('series_deleted', 'series_labels_id')
    ;

    IF _missing THEN
        RETURN;
    END IF;

    -- generate both the detach and attach statements prior to detaching
    -- the partition expression info will be gone after we detach, so we need
    -- to capture it prior to detaching
    SELECT json_agg(
        json_build_object(
            'detach', format('ALTER TABLE _prom_catalog.series DETACH PARTITION %I.%I', x.nspname, x.relname),
            'attach', format('ALTER TABLE _prom_catalog.series ATTACH PARTITION %I.%I %s', x.nspname, x.relname, x.part_expr)
        )
    )
    INTO _cmds
    FROM
    (
        SELECT
            nc.nspname,
            c.relname,
            pg_get_expr(c.relpartbound, c.oid, true) as part_expr
        FROM pg_inherits i
        INNER JOIN pg_class p ON (i.inhparent = p.oid)
        INNER JOIN pg_class c ON (i.inhrelid = c.oid)
        INNER JOIN pg_namespace np ON (np.oid = p.relnamespace)
        INNER JOIN pg_namespace nc ON (nc.oid = c.relnamespace)
        WHERE np.nspname = '_prom_catalog'
        AND p.relname = 'series'
        AND c.relispartition
        AND c.relkind = 'r'
        AND p.relkind = 'p'
        ORDER BY part_expr
    ) x
    ;

    -- detach partitions
    IF _cmds IS NOT NULL THEN
        FOR _cmd IN
        (
            SELECT x->>'detach'
            FROM json_array_elements(_cmds) x
        )
        LOOP
            EXECUTE _cmd;
        END LOOP;
    END IF;

    -- drop indexes from the parent only
    DROP INDEX IF EXISTS _prom_catalog.series_deleted;
    DROP INDEX IF EXISTS _prom_catalog.series_labels_id;

    -- attach the partitions
    IF _cmds IS NOT NULL THEN
        FOR _cmd IN
        (
            SELECT x->>'attach'
            FROM json_array_elements(_cmds) x
        )
        LOOP
            EXECUTE _cmd;
        END LOOP;
    END IF;
END;
$block$;
