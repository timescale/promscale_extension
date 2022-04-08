
DO $block$
DECLARE
    _rec record;
BEGIN
    FOR _rec IN
    (
        -- find functions and procedures which belong to the extension
        -- we are going to be extra paranoid on this
        -- use both pg_depend and schema name to find said functions
        -- and procedures. they *ought* to produce the same list, but
        -- since this is a security measure, paranoia is worth it
        SELECT
            CASE prokind
                WHEN 'f' THEN 'FUNCTION'
                WHEN 'p' THEN 'PROCEDURE'
            END as prokind,
            n.nspname,
            k.proname,
            pg_get_function_identity_arguments(k.oid) as args
        FROM pg_catalog.pg_depend d
        INNER JOIN pg_catalog.pg_extension e ON (d.refobjid = e.oid)
        INNER JOIN pg_catalog.pg_proc k ON (d.objid = k.oid)
        INNER JOIN pg_namespace n ON (k.pronamespace = n.oid)
        WHERE d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
        AND d.deptype = 'e'
        AND e.extname = 'promscale'
        AND k.prokind IN ('f', 'p')
        UNION
        SELECT
            CASE prokind
                WHEN 'f' THEN 'FUNCTION'
                WHEN 'p' THEN 'PROCEDURE'
            END as prokind,
            n.nspname,
            k.proname,
            pg_get_function_identity_arguments(k.oid) as args
        FROM pg_catalog.pg_proc k
        INNER JOIN pg_namespace n ON (k.pronamespace = n.oid)
        WHERE k.prokind IN ('f', 'p')
        AND n.nspname IN
        ( '_prom_catalog'
        , '_prom_ext'
        , '_ps_catalog'
        , '_ps_trace'
        , 'prom_api'
        , 'prom_data'
        , 'prom_data_exemplar'
        , 'prom_data_series'
        , 'prom_info'
        , 'prom_metric'
        , 'prom_series'
        , 'ps_tag'
        , 'ps_trace'
        )
        ORDER BY nspname, proname
    )
    LOOP
        EXECUTE format($$REVOKE ALL ON %s %I.%I(%s) FROM public$$, _rec.prokind, _rec.nspname, _rec.proname, _rec.args);
        -- explicitly make the func/proc owned by the current_user (superuser). if (somehow) a malicious user predefined
        -- a func/proc that we replace, we don't want them to be able to subsequently replace the body with malicious code
        EXECUTE format($$ALTER %s %I.%I(%s) OWNER TO %I$$, _rec.prokind, _rec.nspname, _rec.proname, _rec.args, current_user);
    END LOOP;
END;
$block$;

DO $block$
DECLARE
    _sql text;
BEGIN
    FOR _sql IN
    (
        -- find tables which belong to the extension so we can mark them to have
        -- their data dumped by pg_dump
        SELECT format($$SELECT pg_catalog.pg_extension_config_dump('%I.%I', '')$$, n.nspname, k.relname)
        FROM pg_catalog.pg_depend d
        INNER JOIN pg_catalog.pg_extension e ON (d.refobjid = e.oid)
        INNER JOIN pg_catalog.pg_class k ON (d.objid = k.oid)
        INNER JOIN pg_namespace n ON (k.relnamespace = n.oid)
        WHERE d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
        AND d.deptype = 'e'
        AND e.extname = 'promscale'
        AND k.relkind IN ('r', 'p')
        ORDER BY n.nspname, k.relname
    )
    LOOP
        EXECUTE _sql;
    END LOOP;
END;
$block$;

-- TODO (james): possibly move these grants closer to their definitions? At
--  definition time, the roles which we grant here haven't been created yet.
GRANT EXECUTE ON FUNCTION _prom_ext.num_cpus() TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.jsonb_digest(JSONB) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_delta(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_increase(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_rate(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.vector_selector(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.rewrite_fn_call_to_subquery(internal) TO prom_reader;
GRANT EXECUTE ON PROCEDURE _prom_catalog.execute_everywhere(text, text, boolean) TO prom_admin;
GRANT EXECUTE ON PROCEDURE _prom_catalog.update_execute_everywhere_entry(text, text, boolean) TO prom_admin;
GRANT SELECT ON TABLE _prom_catalog.remote_commands TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.remote_commands TO prom_admin;
GRANT SELECT ON TABLE _ps_catalog.migration TO prom_reader;
