DO $conversion_block$
DECLARE
    _do_conversion boolean = false;
BEGIN
    -- if the public.prom_schema_migrations table still exists then we need to transition
    -- existing database object over to the extension as if they were installed by the extension
    -- if the table does not exist, skip this work
    SELECT count(*) FILTER (WHERE schemaname = 'public' AND tablename = 'prom_schema_migrations') > 0
    INTO STRICT _do_conversion
    FROM pg_tables;
    IF _do_conversion != true THEN
        RAISE LOG 'Skipping conversion maneuver';
        RETURN;
    END IF;
    DROP TABLE public.prom_schema_migrations;

    -- Bring migrations table up to speed
    INSERT INTO _ps_catalog.migration (name, applied_at_version)
    VALUES
        ('001-extension.sql'              , '0.5.0'),
        ('002-utils.sql'                  , '0.5.0'),
        ('003-users.sql'                  , '0.5.0'),
        ('004-schemas.sql'                , '0.5.0'),
        ('005-tag-operators.sql'          , '0.5.0'),
        ('006-tables.sql'                 , '0.5.0'),
        ('007-matcher-operators.sql'      , '0.5.0'),
        ('008-install-uda.sql'            , '0.5.0'),
        ('009-tables-ha.sql'              , '0.5.0'),
        ('010-tables-metadata.sql'        , '0.5.0'),
        ('011-tables-exemplar.sql'        , '0.5.0'),
        ('012-tracing.sql'                , '0.5.0'),
        ('013-tracing-well-known-tags.sql', '0.5.0'),
        ('014-telemetry.sql'              , '0.5.0')
    ;
END;
$conversion_block$;
