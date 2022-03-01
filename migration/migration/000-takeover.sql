--
--This section handles moving objects that were previously unpackaged
--under control of the extension.
--
DO
$takeover_block$
    DECLARE
        _do_takeover boolean = false;
    BEGIN
        SELECT count(*) FILTER (WHERE schemaname = 'public' AND tablename = 'prom_schema_migrations') > 0
        INTO STRICT _do_takeover
        FROM pg_tables;
        IF _do_takeover != true THEN
            RAISE LOG 'Skipping takeover maneuver';
            RETURN;
        END IF;

        DROP TABLE public.prom_schema_migrations;

        -- 001/002
        ALTER EXTENSION promscale ADD SCHEMA _prom_catalog;
        ALTER EXTENSION promscale ADD SCHEMA prom_api;
        ALTER EXTENSION promscale ADD SCHEMA prom_series;
        ALTER EXTENSION promscale ADD SCHEMA prom_metric;
        ALTER EXTENSION promscale ADD SCHEMA prom_data;
        ALTER EXTENSION promscale ADD SCHEMA prom_data_series;
        ALTER EXTENSION promscale ADD SCHEMA prom_info;
        ALTER EXTENSION promscale ADD SCHEMA prom_data_exemplar;
        ALTER EXTENSION promscale ADD SCHEMA ps_tag;
        ALTER EXTENSION promscale ADD SCHEMA _ps_trace;
        ALTER EXTENSION promscale ADD SCHEMA ps_trace;
        ALTER EXTENSION promscale ADD SCHEMA _ps_catalog;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.remote_commands;
        ALTER EXTENSION promscale ADD PROCEDURE _prom_catalog.execute_everywhere(text, text, boolean);
        ALTER EXTENSION promscale ADD PROCEDURE _prom_catalog.update_execute_everywhere_entry(text, text, boolean);
        -- 003
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_jsonb_path_exists;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_regexp_matches;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_regexp_not_matches;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_equals;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_not_equals;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_less_than;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_less_than_or_equal;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_greater_than;
        ALTER EXTENSION promscale ADD TYPE ps_tag.tag_op_greater_than_or_equal;
        -- 004
        ALTER EXTENSION promscale ADD DOMAIN prom_api.label_array;
        ALTER EXTENSION promscale ADD DOMAIN prom_api.label_value_array;
        ALTER EXTENSION promscale ADD TABLE public.prom_installation_info;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.series;
        ALTER EXTENSION promscale ADD SEQUENCE _prom_catalog.series_id;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.label;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.ids_epoch;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.label_key;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.label_key_position;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.metric;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.default;
        -- 005
        ALTER EXTENSION promscale ADD DOMAIN prom_api.matcher_positive;
        ALTER EXTENSION promscale ADD DOMAIN prom_api.matcher_negative;
        ALTER EXTENSION promscale ADD DOMAIN prom_api.label_key;
        ALTER EXTENSION promscale ADD DOMAIN prom_api.pattern;
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_jsonb_each_text(jsonb, out text, out text);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.count_jsonb_keys(jsonb);
        ALTER EXTENSION promscale ADD FUNCTION prom_api.matcher(jsonb);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_contains(prom_api.label_array, jsonb);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_value_contains(prom_api.label_value_array, text);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_match(prom_api.label_array, prom_api.matcher_positive);
        ALTER EXTENSION promscale ADD OPERATOR prom_api.?(prom_api.label_array, prom_api.matcher_positive);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_match(prom_api.label_array, prom_api.matcher_negative);
        ALTER EXTENSION promscale ADD OPERATOR prom_api.?(prom_api.label_array, prom_api.matcher_negative);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_find_key_equal(prom_api.label_key, prom_api.pattern);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_find_key_not_equal(prom_api.label_key, prom_api.pattern);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_find_key_regex(prom_api.label_key, prom_api.pattern);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.label_find_key_not_regex(prom_api.label_key, prom_api.pattern);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.match_equals(prom_api.label_array, ps_tag.tag_op_equals);
        ALTER EXTENSION promscale ADD OPERATOR _prom_catalog.?(prom_api.label_array, ps_tag.tag_op_equals);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.match_not_equals(prom_api.label_array, ps_tag.tag_op_not_equals);
        ALTER EXTENSION promscale ADD OPERATOR _prom_catalog.?(prom_api.label_array, ps_tag.tag_op_not_equals);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.match_regexp_matches(prom_api.label_array, ps_tag.tag_op_regexp_matches);
        ALTER EXTENSION promscale ADD OPERATOR _prom_catalog.?(prom_api.label_array, ps_tag.tag_op_regexp_matches);
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.match_regexp_not_matches(prom_api.label_array, ps_tag.tag_op_regexp_not_matches);
        ALTER EXTENSION promscale ADD OPERATOR _prom_catalog.?(prom_api.label_array, ps_tag.tag_op_regexp_not_matches);
        -- 006
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.get_timescale_major_version();
        ALTER EXTENSION promscale ADD PROCEDURE _prom_catalog.execute_maintenance_job(int, jsonb);
        -- 007
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.ha_leases;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.ha_leases_logs;
        ALTER EXTENSION promscale ADD FUNCTION _prom_catalog.ha_leases_audit_fn();
        -- 008
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.metadata;
        -- 009
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.exemplar_label_key_position;
        ALTER EXTENSION promscale ADD TABLE _prom_catalog.exemplar;
        -- 010
        ALTER EXTENSION promscale ADD DOMAIN ps_trace.trace_id;
        ALTER EXTENSION promscale ADD DOMAIN ps_trace.tag_k;
        ALTER EXTENSION promscale ADD DOMAIN ps_trace.tag_v;
        ALTER EXTENSION promscale ADD DOMAIN ps_trace.tag_map;
        ALTER EXTENSION promscale ADD DOMAIN ps_trace.tag_type;
        ALTER EXTENSION promscale ADD TYPE ps_trace.span_kind;
        ALTER EXTENSION promscale ADD TYPE ps_trace.status_code;
        ALTER EXTENSION promscale ADD TYPE _ps_trace.tag_key;
        ALTER EXTENSION promscale ADD TYPE _ps_trace.tag;
        DO $block$
            DECLARE
                _i bigint;
                _max bigint = 64;
            BEGIN
                FOR _i IN 1.._max
                    LOOP
                        EXECUTE format($sql$
                    ALTER EXTENSION promscale ADD TABLE _ps_trace.tag_%s;
                    $sql$, _i);
                    END LOOP;
            END
        $block$
        ;
        ALTER EXTENSION promscale ADD TABLE _ps_trace.operation;
        ALTER EXTENSION promscale ADD TABLE _ps_trace.schema_url;
        ALTER EXTENSION promscale ADD TABLE _ps_trace.instrumentation_lib;
        ALTER EXTENSION promscale ADD TABLE _ps_trace.span;
        ALTER EXTENSION promscale ADD TABLE _ps_trace.event;
        ALTER EXTENSION promscale ADD TABLE _ps_trace.link;
        -- 012
        ALTER EXTENSION promscale ADD TABLE _ps_catalog.promscale_instance_information;

        -- Bring migrations table up to speed
        INSERT INTO _ps_catalog.migration (name, applied_at_version)
        VALUES
            ('001-extension.sql', '0.5.0'),
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

        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.default', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.exemplar', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.exemplar_label_key_position', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.ha_leases', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.ha_leases_logs', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.ids_epoch', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.label', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.label_key', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.label_key_position', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.metadata', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.metric', '');
        PERFORM pg_catalog.pg_extension_config_dump('_prom_catalog.remote_commands', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_catalog.migration', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_catalog.promscale_instance_information', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.event', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.instrumentation_lib', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.link', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.operation', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.schema_url', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.span', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_1', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_10', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_11', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_12', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_13', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_14', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_15', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_16', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_17', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_18', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_19', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_2', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_20', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_21', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_22', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_23', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_24', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_25', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_26', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_27', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_28', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_29', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_3', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_30', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_31', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_32', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_33', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_34', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_35', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_36', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_37', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_38', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_39', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_4', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_40', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_41', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_42', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_43', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_44', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_45', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_46', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_47', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_48', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_49', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_5', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_50', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_51', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_52', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_53', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_54', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_55', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_56', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_57', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_58', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_59', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_6', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_60', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_61', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_62', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_63', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_64', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_7', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_8', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_9', '');
        PERFORM pg_catalog.pg_extension_config_dump('_ps_trace.tag_key', '');
        PERFORM pg_catalog.pg_extension_config_dump('public.prom_installation_info', '');

    END;
$takeover_block$;
