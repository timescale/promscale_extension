CALL _prom_catalog.execute_everywhere('create_prom_reader', $ee$
    DO $$
        BEGIN
            CREATE ROLE prom_reader;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'role prom_reader already exists, skipping create';
            RETURN;
        END
    $$;
$ee$);

CALL _prom_catalog.execute_everywhere('create_prom_writer', $ee$
    DO $$
        BEGIN
            CREATE ROLE prom_writer;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'role prom_writer already exists, skipping create';
            RETURN;
        END
    $$;
$ee$);

CALL _prom_catalog.execute_everywhere('create_prom_modifier', $ee$
    DO $$
        BEGIN
            CREATE ROLE prom_modifier;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'role prom_modifier already exists, skipping create';
            RETURN;
        END
    $$;
$ee$);

CALL _prom_catalog.execute_everywhere('create_prom_admin', $ee$
    DO $$
        BEGIN
            CREATE ROLE prom_admin;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'role prom_admin already exists, skipping create';
            RETURN;
        END
    $$;
$ee$);

CALL _prom_catalog.execute_everywhere('create_prom_maintenance', $ee$
    DO $$
        BEGIN
            CREATE ROLE prom_maintenance;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'role prom_maintenance already exists, skipping create';
            RETURN;
        END
    $$;
$ee$);

CALL _prom_catalog.execute_everywhere('grant_prom_reader_prom_writer',$ee$
    DO $$
    BEGIN
        GRANT prom_reader TO prom_writer;
        GRANT prom_reader TO prom_maintenance;
        GRANT prom_writer TO prom_modifier;
        GRANT prom_modifier TO prom_admin;
        GRANT prom_maintenance TO prom_admin;
    END
    $$;
$ee$);

-- TODO (james): possibly move these grants closer to their definitions? At
--  definition time, the roles which we grant here haven't been created yet.
GRANT EXECUTE ON FUNCTION _prom_ext.num_cpus() TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_delta(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_increase(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_rate(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.vector_selector(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.update_tsprom_metadata(TEXT, TEXT, BOOLEAN) TO prom_writer;
GRANT EXECUTE ON FUNCTION _prom_ext.rewrite_fn_call_to_subquery(internal) TO prom_reader;