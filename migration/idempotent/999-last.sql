-- this script always runs last in the upgrade process
-- it is intended for things that NEED to run last

-- monkey with the remote_commands to ensure order
DO $block$
BEGIN
    /*
    Some remote commands are registered in the preinstall or upgrade scripts.

    Two remote commands are registered in the idempotent scripts which get run
    at the end of a fresh install and after every version upgrade. Thus, it's
    difficult to know where in the sequence these two will show up.

    This update will ensure a consistent ordering of our remote commands and
    place any potential user defined remote commands after ours in
    original order starting with seq number 1000.
    */
    WITH x(key, seq) AS
    (
        VALUES
        ('create_prom_reader'                        ,  1),
        ('create_prom_writer'                        ,  2),
        ('create_prom_modifier'                      ,  3),
        ('create_prom_admin'                         ,  4),
        ('create_prom_maintenance'                   ,  5),
        ('grant_prom_reader_prom_writer'             ,  6),
        ('tracing_types'                             ,  7),
        ('grant_all_roles_to_extowner'               ,  8),
        ('_prom_catalog.do_decompress_chunks_after'  ,  9),
        ('_prom_catalog.compress_old_chunks'         , 10)
    )
    UPDATE _prom_catalog.remote_commands u SET seq = z.seq
    FROM
    (
        -- our remote commands from above
        SELECT key, seq
        FROM x
        UNION
        -- any other remote commands get listed afterwards starting with 1000
        SELECT key, 999 + row_number() OVER (ORDER BY seq)
        FROM _prom_catalog.remote_commands k
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM x
            WHERE x.key = k.key
        )
        ORDER BY seq
    ) z
    WHERE u.key = z.key
    ;

    /*
    There are known entries listed above that are managed by this script.
    Other entries in the table are inserted "dynamically" (e.g. when metrics are created).
    The dynamic entries need to be dumped by pg_dump. We will start the sequence at a
    minimum of 1000 so that we can identify them as such.
    */
    PERFORM setval('_prom_catalog.remote_commands_seq_seq'::regclass, greatest(1000, max(seq) + 1), false)
    FROM _prom_catalog.remote_commands
    ;
END;
$block$;

-- security check on functions and procedures
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

-- make sure tables and sequences are pg_dump'ed properly
DO $block$
DECLARE
    _sql text;
BEGIN
    FOR _sql IN
    (
        -- find tables and sequences which belong to the extension so we can mark them to have
        -- their data dumped by pg_dump
        SELECT format($$SELECT pg_catalog.pg_extension_config_dump('%I.%I', %L)$$,
            n.nspname,
            k.relname,
            case (n.nspname, k.relname)
                when ('_prom_catalog'::name, 'remote_commands'::name) then 'where seq >= 1000'
                when ('_ps_trace'::name, 'tag_key'::name) then 'where id >= 1000'
                else ''
            end)
        FROM pg_catalog.pg_depend d
        INNER JOIN pg_catalog.pg_extension e ON (d.refobjid = e.oid)
        INNER JOIN pg_catalog.pg_class k ON (d.objid = k.oid)
        INNER JOIN pg_namespace n ON (k.relnamespace = n.oid)
        WHERE d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
        AND d.deptype = 'e'
        AND e.extname = 'promscale'
        AND k.relkind IN ('r', 'p', 'S') -- tables AND sequences
        AND (n.nspname, k.relname) NOT IN
        (
            -- these should NOT be config tables
            -- migration table will be populated by the installation of extension
            ('_ps_catalog'::name, 'migration'::name),
            -- we want the telemetry data reset with restores
            ('_ps_catalog'::name, 'promscale_instance_information'::name)
        )
        ORDER BY n.nspname, k.relname
    )
    LOOP
        EXECUTE _sql;
    END LOOP;
END;
$block$;

-- make sure prom_admin can do a dump/restore
DO $$
DECLARE
    _rec record;
    _schema text;
    _schemas text[] = ARRAY
    [ '_prom_catalog'
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
    ];
BEGIN
    -- grant schema privileges
    FOREACH _schema IN ARRAY _schemas
    LOOP
        EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO prom_admin', _schema);
    END LOOP;

    -- grant table/sequence privileges
    FOR _rec IN
    (
        SELECT
            n.nspname,
            k.relname,
            case k.relkind
                when 'S' then 'SEQUENCE'
                else 'TABLE'
            end as kind
        FROM pg_catalog.pg_class k
        INNER JOIN pg_namespace n ON (k.relnamespace = n.oid)
        WHERE k.relkind IN ('r', 'p', 'S') -- tables AND sequences
        AND n.nspname = ANY(_schemas)
        ORDER BY k.relkind, n.nspname, k.relname
    )
    LOOP
        EXECUTE format('GRANT ALL PRIVILEGES ON %s %I.%I TO prom_admin', _rec.kind, _rec.nspname, _rec.relname);
    END LOOP;
END$$;
