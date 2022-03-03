--
--This section handles moving objects that were previously unpackaged
--under control of the extension.
--
DO $takeover_block$
DECLARE
    _do_takeover boolean = false;

BEGIN
    -- if the public.prom_schema_migrations table still exists then we need to transition
    -- existing database object over to the extension as if they were installed by the extension
    -- if the table does not exist, skip this work
    SELECT count(*) FILTER (WHERE schemaname = 'public' AND tablename = 'prom_schema_migrations') > 0
    INTO STRICT _do_takeover
    FROM pg_tables;
    IF _do_takeover != true THEN
        RAISE LOG 'Skipping takeover maneuver';
        RETURN;
    END IF;
    DROP TABLE public.prom_schema_migrations;

    -- schemas
    DO $block$
    DECLARE
        _rec record;
    BEGIN
        FOR _rec IN
        (
            select *
            from (
            values
              ('SCHEMA', '_prom_catalog')
            , ('SCHEMA', '_prom_ext')
            , ('SCHEMA', '_ps_catalog')
            , ('SCHEMA', '_ps_trace')
            , ('SCHEMA', 'prom_api')
            , ('SCHEMA', 'prom_data')
            , ('SCHEMA', 'prom_data_exemplar')
            , ('SCHEMA', 'prom_data_series')
            , ('SCHEMA', 'prom_info')
            , ('SCHEMA', 'prom_metric')
            , ('SCHEMA', 'prom_series')
            , ('SCHEMA', 'ps_tag')
            , ('SCHEMA', 'ps_trace')
            , ('TABLE', '_prom_catalog.remote_commands')
            , ('TABLE', 'public.prom_installation_info')
            , ('TABLE', '_prom_catalog.series')
            , ('TABLE', '_prom_catalog.label')
            , ('TABLE', '_prom_catalog.ids_epoch')
            , ('TABLE', '_prom_catalog.label_key')
            , ('TABLE', '_prom_catalog.label_key_position')
            , ('TABLE', '_prom_catalog.metric')
            , ('TABLE', '_prom_catalog.default')
            , ('TABLE', '_prom_catalog.ha_leases')
            , ('TABLE', '_prom_catalog.ha_leases_logs')
            , ('TABLE', '_prom_catalog.metadata')
            , ('TABLE', '_prom_catalog.exemplar_label_key_position')
            , ('TABLE', '_prom_catalog.exemplar')
            , ('TABLE', '_ps_trace.operation')
            , ('TABLE', '_ps_trace.schema_url')
            , ('TABLE', '_ps_trace.instrumentation_lib')
            , ('TABLE', '_ps_trace.span')
            , ('TABLE', '_ps_trace.event')
            , ('TABLE', '_ps_trace.link')
            , ('TABLE', '_ps_catalog.promscale_instance_information')
            , ('PROCEDURE', '_prom_catalog.execute_everywhere(text, text, boolean)')
            , ('PROCEDURE', '_prom_catalog.update_execute_everywhere_entry(text, text, boolean)')
            , ('FUNCTION', '_prom_catalog.get_timescale_major_version()')
            , ('FUNCTION', '_prom_catalog.ha_leases_audit_fn()')
            , ('FUNCTION', '_prom_catalog.label_jsonb_each_text(jsonb, out text, out text)')
            , ('FUNCTION', '_prom_catalog.count_jsonb_keys(jsonb)')
            , ('FUNCTION', 'prom_api.matcher(jsonb)')
            , ('FUNCTION', '_prom_catalog.label_contains(prom_api.label_array, jsonb)')
            , ('FUNCTION', '_prom_catalog.label_value_contains(prom_api.label_value_array, text)')
            , ('FUNCTION', '_prom_catalog.label_match(prom_api.label_array, prom_api.matcher_positive)')
            , ('FUNCTION', '_prom_catalog.label_match(prom_api.label_array, prom_api.matcher_negative)')
            , ('FUNCTION', '_prom_catalog.label_find_key_equal(prom_api.label_key, prom_api.pattern)')
            , ('FUNCTION', '_prom_catalog.label_find_key_not_equal(prom_api.label_key, prom_api.pattern)')
            , ('FUNCTION', '_prom_catalog.label_find_key_regex(prom_api.label_key, prom_api.pattern)')
            , ('FUNCTION', '_prom_catalog.label_find_key_not_regex(prom_api.label_key, prom_api.pattern)')
            , ('FUNCTION', '_prom_catalog.match_equals(prom_api.label_array, ps_tag.tag_op_equals)')
            , ('FUNCTION', '_prom_catalog.match_not_equals(prom_api.label_array, ps_tag.tag_op_not_equals)')
            , ('FUNCTION', '_prom_catalog.match_regexp_matches(prom_api.label_array, ps_tag.tag_op_regexp_matches)')
            , ('FUNCTION', '_prom_catalog.match_regexp_not_matches(prom_api.label_array, ps_tag.tag_op_regexp_not_matches)')
            , ('FUNCTION', '_prom_catalog.get_timescale_major_version()')
            , ('FUNCTION', '_prom_catalog.ha_leases_audit_fn()')
            , ('TYPE', 'ps_tag.tag_op_jsonb_path_exists')
            , ('TYPE', 'ps_tag.tag_op_regexp_matches')
            , ('TYPE', 'ps_tag.tag_op_regexp_not_matches')
            , ('TYPE', 'ps_tag.tag_op_equals')
            , ('TYPE', 'ps_tag.tag_op_not_equals')
            , ('TYPE', 'ps_tag.tag_op_less_than')
            , ('TYPE', 'ps_tag.tag_op_less_than_or_equal')
            , ('TYPE', 'ps_tag.tag_op_greater_than')
            , ('TYPE', 'ps_tag.tag_op_greater_than_or_equal')
            , ('TYPE', 'ps_trace.span_kind')
            , ('TYPE', 'ps_trace.status_code')
            , ('TYPE', '_ps_trace.tag_key')
            , ('TYPE', '_ps_trace.tag')
            , ('DOMAIN', 'prom_api.label_array')
            , ('DOMAIN', 'prom_api.label_value_array')
            , ('DOMAIN', 'prom_api.matcher_positive')
            , ('DOMAIN', 'prom_api.matcher_negative')
            , ('DOMAIN', 'prom_api.label_key')
            , ('DOMAIN', 'prom_api.pattern')
            , ('DOMAIN', 'ps_trace.trace_id')
            , ('DOMAIN', 'ps_trace.tag_k')
            , ('DOMAIN', 'ps_trace.tag_v')
            , ('DOMAIN', 'ps_trace.tag_map')
            , ('DOMAIN', 'ps_trace.tag_type')
            , ('SEQUENCE', '_prom_catalog.series_id')
            , ('OPERATOR', 'prom_api.?(prom_api.label_array, prom_api.matcher_positive)')
            , ('OPERATOR', 'prom_api.?(prom_api.label_array, prom_api.matcher_negative)')
            , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_equals)')
            , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_not_equals)')
            , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_regexp_matches)')
            , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_regexp_not_matches)')
            ) x(objtype, objname)
        )
        LOOP
            EXECUTE format('ALTER %s promscale ADD SCHEMA %s', _rec.objtype, _rec.objname);
            EXECUTE format('ALTER %s %s OWNER TO %I', _rec.objtype, _rec.objname, @extowner@);

            IF _rec.objtype = 'TABLE' THEN
                EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump(%L, '')$sql$, _rec.objname);
            END IF;
        END LOOP;
    END;
    $block$;

    -- tag partition tables
    DO $block$
    DECLARE
        _i bigint;
        _max bigint = 64;
    BEGIN
        FOR _i IN 1.._max
        LOOP
            EXECUTE format($sql$ALTER EXTENSION promscale ADD TABLE _ps_trace.tag_%s;$sql$, _i);
            EXECUTE format($sql$ALTER TABLE _ps_trace.tag_%s OWNER TO %I$sql$, _i, @extowner@);
            EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump('_ps_trace.tag_%s', '')$sql$, _i);
       END LOOP;
    END
    $block$
    ;

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
$takeover_block$;
