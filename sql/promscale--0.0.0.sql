SET LOCAL search_path = pg_catalog, pg_temp;

--stop background workers; see note in bootstrap/002-stop-bgw.sql
DO
$stop_bgw$
DECLARE
    _is_timescaledb_installed boolean = false;
BEGIN
    SELECT count(*) > 0
    INTO STRICT _is_timescaledb_installed
    FROM pg_extension
    WHERE extname='timescaledb';

    IF _is_timescaledb_installed THEN
        PERFORM _timescaledb_internal.restart_background_workers();
    END IF;
END;
$stop_bgw$;

DROP TABLE public.prom_schema_migrations;

REVOKE EXECUTE ON FUNCTION ps_trace.delete_all_traces() FROM prom_writer;
REVOKE EXECUTE ON PROCEDURE prom_api.add_prom_node(TEXT, BOOLEAN) FROM prom_writer;

DROP OPERATOR IF EXISTS prom_api.!== (prom_api.label_key, prom_api.pattern);
DROP OPERATOR IF EXISTS prom_api.!=~ (prom_api.label_key, prom_api.pattern);
DROP OPERATOR IF EXISTS prom_api.== (prom_api.label_key, prom_api.pattern);
DROP OPERATOR IF EXISTS prom_api.==~ (prom_api.label_key, prom_api.pattern);

DO $block$
DECLARE
    _rec record;
    _config_filter text;
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
        , ('TABLE', '_prom_catalog.default')
        , ('TABLE', '_prom_catalog.exemplar')
        , ('TABLE', '_prom_catalog.exemplar_label_key_position')
        , ('TABLE', '_prom_catalog.ha_leases')
        , ('TABLE', '_prom_catalog.ha_leases_logs')
        , ('TABLE', '_prom_catalog.ids_epoch')
        , ('TABLE', '_prom_catalog.label')
        , ('TABLE', '_prom_catalog.label_key')
        , ('TABLE', '_prom_catalog.label_key_position')
        , ('TABLE', '_prom_catalog.metadata')
        , ('TABLE', '_prom_catalog.metric')
        , ('TABLE', '_prom_catalog.remote_commands')
        , ('TABLE', '_prom_catalog.series')
        , ('TABLE', '_ps_catalog.promscale_instance_information')
        , ('TABLE', '_ps_trace.event')
        , ('TABLE', '_ps_trace.instrumentation_lib')
        , ('TABLE', '_ps_trace.link')
        , ('TABLE', '_ps_trace.operation')
        , ('TABLE', '_ps_trace.schema_url')
        , ('TABLE', '_ps_trace.span')
        , ('TABLE', '_ps_trace.tag')
        , ('TABLE', '_ps_trace.tag_key')
        --, ('TABLE', 'public.prom_installation_info') this will be dropped immediately in 0.5.0
        , ('VIEW', 'prom_info.label')
        , ('VIEW', 'prom_info.metric')
        , ('VIEW', 'prom_info.metric_stats')
        , ('VIEW', 'prom_info.system_stats')
        , ('VIEW', 'ps_trace.event')
        , ('VIEW', 'ps_trace.link')
        , ('VIEW', 'ps_trace.span')
        , ('SEQUENCE', '_prom_catalog.exemplar_id_seq')
        , ('SEQUENCE', '_prom_catalog.label_id_seq')
        , ('SEQUENCE', '_prom_catalog.label_key_id_seq')
        , ('SEQUENCE', '_prom_catalog.metric_id_seq')
        , ('SEQUENCE', '_prom_catalog.remote_commands_seq_seq')
        , ('SEQUENCE', '_prom_catalog.series_id')
        , ('SEQUENCE', '_ps_trace.instrumentation_lib_id_seq')
        , ('SEQUENCE', '_ps_trace.operation_id_seq')
        , ('SEQUENCE', '_ps_trace.schema_url_id_seq')
        , ('SEQUENCE', '_ps_trace.tag_id_seq')
        , ('SEQUENCE', '_ps_trace.tag_key_id_seq')
        , ('TYPE', 'ps_tag.tag_op_equals')
        , ('TYPE', 'ps_tag.tag_op_greater_than')
        , ('TYPE', 'ps_tag.tag_op_greater_than_or_equal')
        , ('TYPE', 'ps_tag.tag_op_jsonb_path_exists')
        , ('TYPE', 'ps_tag.tag_op_less_than')
        , ('TYPE', 'ps_tag.tag_op_less_than_or_equal')
        , ('TYPE', 'ps_tag.tag_op_not_equals')
        , ('TYPE', 'ps_tag.tag_op_regexp_matches')
        , ('TYPE', 'ps_tag.tag_op_regexp_not_matches')
        , ('DOMAIN', 'prom_api.label_array')
        , ('DOMAIN', 'prom_api.label_key')
        , ('DOMAIN', 'prom_api.label_value_array')
        , ('DOMAIN', 'prom_api.matcher_negative')
        , ('DOMAIN', 'prom_api.matcher_positive')
        , ('DOMAIN', 'prom_api.pattern')
        , ('DOMAIN', 'ps_trace.tag_k')
        , ('DOMAIN', 'ps_trace.tag_map')
        , ('DOMAIN', 'ps_trace.tag_type')
        , ('DOMAIN', 'ps_trace.tag_v')
        , ('DOMAIN', 'ps_trace.trace_id')
        , ('TYPE', 'ps_trace.span_kind') -- enum
        , ('TYPE', 'ps_trace.status_code') -- enum
        , ('FUNCTION', '_prom_catalog.attach_series_partition(metric_record _prom_catalog.metric)')
        , ('FUNCTION', '_prom_catalog.compress_chunk_for_metric(metric_table text, chunk_schema_name name, chunk_table_name name)')
        , ('FUNCTION', '_prom_catalog.count_jsonb_keys(j jsonb)')
        , ('FUNCTION', '_prom_catalog.create_exemplar_table_if_not_exists(metric_name text)')
        , ('FUNCTION', '_prom_catalog.create_label_key(new_key text, OUT id integer, OUT value_column_name name, OUT id_column_name name)')
        , ('FUNCTION', '_prom_catalog.create_metric_table(metric_name_arg text, OUT id integer, OUT table_name name)')
        , ('FUNCTION', '_prom_catalog.create_metric_view(metric_name text)')
        , ('FUNCTION', '_prom_catalog.create_series(metric_id integer, metric_table_name name, label_array prom_api.label_array, OUT series_id bigint)')
        , ('FUNCTION', '_prom_catalog.create_series_view(metric_name text)')
        , ('FUNCTION', '_prom_catalog.decompress_chunk_for_metric(metric_table text, chunk_schema_name name, chunk_table_name name)')
        , ('FUNCTION', '_prom_catalog.delay_compression_job(ht_table name, new_start timestamp with time zone)')
        , ('FUNCTION', '_prom_catalog.delete_expired_series(metric_schema text, metric_table text, metric_series_table text, ran_at timestamp with time zone, present_epoch bigint, last_updated_epoch timestamp with time zone)')
        , ('FUNCTION', '_prom_catalog.delete_series_catalog_row(metric_table name, series_ids bigint[])')
        , ('FUNCTION', '_prom_catalog.delete_series_from_metric(name text, series_ids bigint[])')
        , ('FUNCTION', '_prom_catalog.drop_metric_chunk_data(schema_name text, metric_name text, older_than timestamp with time zone)')
        , ('FUNCTION', '_prom_catalog.epoch_abort(user_epoch bigint)')
        , ('FUNCTION', '_prom_catalog.get_advisory_lock_prefix_job()')
        , ('FUNCTION', '_prom_catalog.get_advisory_lock_prefix_maintenance()')
        , ('FUNCTION', '_prom_catalog.get_cagg_info(metric_schema text, metric_table text, OUT is_cagg boolean, OUT cagg_schema name, OUT cagg_name name, OUT metric_table_name name, OUT materialized_hypertable_id integer, OUT storage_hypertable_relation text)')
        , ('FUNCTION', '_prom_catalog.get_confirmed_unused_series(metric_schema name, metric_table name, series_table name, potential_series_ids bigint[], check_time timestamp with time zone)')
        , ('FUNCTION', '_prom_catalog.get_default_chunk_interval()')
        , ('FUNCTION', '_prom_catalog.get_default_compression_setting()')
        , ('FUNCTION', '_prom_catalog.get_default_retention_period()')
        , ('FUNCTION', '_prom_catalog.get_exemplar_label_key_positions(metric_name text)')
        , ('FUNCTION', '_prom_catalog.get_first_level_view_on_metric(metric_schema text, metric_table text)')
        , ('FUNCTION', '_prom_catalog.get_label_key_column_name_for_view(label_key text, id boolean)')
        , ('FUNCTION', '_prom_catalog.get_metric_compression_setting(metric_name text)')
        , ('FUNCTION', '_prom_catalog.get_metric_retention_period(metric_name text)')
        , ('FUNCTION', '_prom_catalog.get_metric_retention_period(schema_name text, metric_name text)')
        , ('FUNCTION', '_prom_catalog.get_metric_table_name_if_exists(schema text, metric_name text)')
        , ('FUNCTION', '_prom_catalog.get_metrics_that_need_compression()')
        , ('FUNCTION', '_prom_catalog.get_metrics_that_need_drop_chunk()')
        , ('FUNCTION', '_prom_catalog.get_new_label_id(key_name text, value_name text, OUT id integer)')
        , ('FUNCTION', '_prom_catalog.get_new_pos_for_key(metric_name text, metric_table name, key_name_array text[], is_for_exemplar boolean)')
        , ('FUNCTION', '_prom_catalog.get_or_create_label_array(metric_name text, label_keys text[], label_values text[])')
        , ('FUNCTION', '_prom_catalog.get_or_create_label_array(js jsonb)')
        , ('FUNCTION', '_prom_catalog.get_or_create_label_id(key_name text, value_name text)')
        , ('FUNCTION', '_prom_catalog.get_or_create_label_ids(metric_name text, metric_table name, label_keys text[], label_values text[])')
        , ('FUNCTION', '_prom_catalog.get_or_create_label_key(key text, OUT id integer, OUT value_column_name name, OUT id_column_name name)')
        , ('FUNCTION', '_prom_catalog.get_or_create_label_key_pos(metric_name text, key text)')
        , ('FUNCTION', '_prom_catalog.get_or_create_metric_table_name(metric_name text, OUT id integer, OUT table_name name, OUT possibly_new boolean)')
        , ('FUNCTION', '_prom_catalog.get_or_create_series_id(label jsonb)')
        , ('FUNCTION', '_prom_catalog.get_or_create_series_id_for_kv_array(metric_name text, label_keys text[], label_values text[], OUT table_name name, OUT series_id bigint)')
        , ('FUNCTION', '_prom_catalog.get_or_create_series_id_for_label_array(metric_id integer, table_name name, larray prom_api.label_array, OUT series_id bigint)')
        , ('FUNCTION', '_prom_catalog.get_staggered_chunk_interval(chunk_interval interval)')
        , ('FUNCTION', '_prom_catalog.get_storage_hypertable_info(metric_schema_name text, metric_table_name text, is_view boolean)')
        , ('FUNCTION', '_prom_catalog.get_timescale_major_version()')
        , ('FUNCTION', '_prom_catalog.get_timescale_minor_version()')
        , ('FUNCTION', '_prom_catalog.ha_leases_audit_fn()')
        , ('FUNCTION', '_prom_catalog.hypertable_compression_stats_for_schema(schema_name_in name)')
        , ('FUNCTION', '_prom_catalog.hypertable_local_size(schema_name_in name)')
        , ('FUNCTION', '_prom_catalog.hypertable_node_up(schema_name_in name)')
        , ('FUNCTION', '_prom_catalog.hypertable_remote_size(schema_name_in name)')
        , ('FUNCTION', '_prom_catalog.insert_exemplar_row(metric_table name, time_array timestamp with time zone[], series_id_array bigint[], exemplar_label_values_array prom_api.label_value_array[], value_array double precision[])')
        , ('FUNCTION', '_prom_catalog.insert_metric_metadatas(t timestamp with time zone[], metric_family_name text[], metric_type text[], metric_unit text[], metric_help text[])')
        , ('FUNCTION', '_prom_catalog.insert_metric_row(metric_table name, time_array timestamp with time zone[], value_array double precision[], series_id_array bigint[])')
        , ('FUNCTION', '_prom_catalog.is_multinode()')
        , ('FUNCTION', '_prom_catalog.is_timescaledb_installed()')
        , ('FUNCTION', '_prom_catalog.is_timescaledb_oss()')
        , ('FUNCTION', '_prom_catalog.label_contains(labels prom_api.label_array, json_labels jsonb)')
        , ('FUNCTION', '_prom_catalog.label_find_key_equal(key_to_match prom_api.label_key, pat prom_api.pattern)')
        , ('FUNCTION', '_prom_catalog.label_find_key_not_equal(key_to_match prom_api.label_key, pat prom_api.pattern)')
        , ('FUNCTION', '_prom_catalog.label_find_key_not_regex(key_to_match prom_api.label_key, pat prom_api.pattern)')
        , ('FUNCTION', '_prom_catalog.label_find_key_regex(key_to_match prom_api.label_key, pat prom_api.pattern)')
        , ('FUNCTION', '_prom_catalog.label_jsonb_each_text(js jsonb, OUT key text, OUT value text)')
        , ('FUNCTION', '_prom_catalog.label_match(labels prom_api.label_array, matchers prom_api.matcher_negative)')
        , ('FUNCTION', '_prom_catalog.label_match(labels prom_api.label_array, matchers prom_api.matcher_positive)')
        , ('FUNCTION', '_prom_catalog.label_unnest(label_array anyarray)')
        , ('FUNCTION', '_prom_catalog.label_value_contains(labels prom_api.label_value_array, label_value text)')
        , ('FUNCTION', '_prom_catalog.lock_metric_for_maintenance(metric_id integer, wait boolean)')
        , ('FUNCTION', '_prom_catalog.make_metric_table()')
        , ('FUNCTION', '_prom_catalog.mark_unused_series(metric_schema text, metric_table text, metric_series_table text, older_than timestamp with time zone, check_time timestamp with time zone)')
        , ('FUNCTION', '_prom_catalog.match_equals(labels prom_api.label_array, _op ps_tag.tag_op_equals)')
        , ('FUNCTION', '_prom_catalog.match_not_equals(labels prom_api.label_array, _op ps_tag.tag_op_not_equals)')
        , ('FUNCTION', '_prom_catalog.match_regexp_matches(labels prom_api.label_array, _op ps_tag.tag_op_regexp_matches)')
        , ('FUNCTION', '_prom_catalog.match_regexp_not_matches(labels prom_api.label_array, _op ps_tag.tag_op_regexp_not_matches)')
        , ('FUNCTION', '_prom_catalog.metric_view()')
        , ('FUNCTION', '_prom_catalog.pg_name_unique(full_name_arg text, suffix text)')
        , ('FUNCTION', '_prom_catalog.pg_name_with_suffix(full_name text, suffix text)')
        , ('FUNCTION', '_prom_catalog.resurrect_series_ids(metric_table name, series_id bigint)')
        , ('FUNCTION', '_prom_catalog.safe_approximate_row_count(table_name_input regclass)')
        , ('FUNCTION', '_prom_catalog.set_app_name(full_name text)')
        , ('FUNCTION', '_prom_catalog.set_chunk_interval_on_metric_table(metric_name text, new_interval interval)')
        , ('FUNCTION', '_prom_catalog.try_change_leader(cluster text, new_leader text, max_time timestamp with time zone)')
        , ('FUNCTION', '_prom_catalog.unlock_metric_for_maintenance(metric_id integer)')
        , ('FUNCTION', '_prom_catalog.update_lease(cluster text, writer text, min_time timestamp with time zone, max_time timestamp with time zone)')
        , ('FUNCTION', '_ps_catalog.apply_telemetry(telemetry_name text, telemetry_value text)')
        , ('FUNCTION', '_ps_catalog.promscale_sql_telemetry()')
        , ('FUNCTION', '_ps_catalog.promscale_telemetry_housekeeping(telemetry_sync_duration interval)')
        , ('FUNCTION', '_ps_trace.eval_equals(_op ps_tag.tag_op_equals)')
        , ('FUNCTION', '_ps_trace.eval_greater_than(_op ps_tag.tag_op_greater_than)')
        , ('FUNCTION', '_ps_trace.eval_greater_than_or_equal(_op ps_tag.tag_op_greater_than_or_equal)')
        , ('FUNCTION', '_ps_trace.eval_jsonb_path_exists(_op ps_tag.tag_op_jsonb_path_exists)')
        , ('FUNCTION', '_ps_trace.eval_less_than(_op ps_tag.tag_op_less_than)')
        , ('FUNCTION', '_ps_trace.eval_less_than_or_equal(_op ps_tag.tag_op_less_than_or_equal)')
        , ('FUNCTION', '_ps_trace.eval_not_equals(_op ps_tag.tag_op_not_equals)')
        , ('FUNCTION', '_ps_trace.eval_regexp_matches(_op ps_tag.tag_op_regexp_matches)')
        , ('FUNCTION', '_ps_trace.eval_regexp_not_matches(_op ps_tag.tag_op_regexp_not_matches)')
        , ('FUNCTION', '_ps_trace.eval_tags_by_key(_key ps_trace.tag_k)')
        , ('FUNCTION', '_ps_trace.get_tag_id(_tag_map ps_trace.tag_map, _key ps_trace.tag_k)')
        , ('FUNCTION', '_ps_trace.has_tag(_tag_map ps_trace.tag_map, _key ps_trace.tag_k)')
        , ('FUNCTION', '_ps_trace.match_equals(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_equals)')
        , ('FUNCTION', '_ps_trace.match_greater_than(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_greater_than)')
        , ('FUNCTION', '_ps_trace.match_greater_than_or_equal(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_greater_than_or_equal)')
        , ('FUNCTION', '_ps_trace.match_jsonb_path_exists(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_jsonb_path_exists)')
        , ('FUNCTION', '_ps_trace.match_less_than(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_less_than)')
        , ('FUNCTION', '_ps_trace.match_less_than_or_equal(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_less_than_or_equal)')
        , ('FUNCTION', '_ps_trace.match_not_equals(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_not_equals)')
        , ('FUNCTION', '_ps_trace.match_regexp_matches(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_regexp_matches)')
        , ('FUNCTION', '_ps_trace.match_regexp_not_matches(_tag_map ps_trace.tag_map, _op ps_tag.tag_op_regexp_not_matches)')
        , ('FUNCTION', 'prom_api.config_maintenance_jobs(number_jobs integer, new_schedule_interval interval, new_config jsonb)')
        , ('FUNCTION', 'prom_api.drop_metric(metric_name_to_be_dropped text)')
        , ('FUNCTION', 'prom_api.eq(labels1 prom_api.label_array, matchers prom_api.matcher_positive)')
        , ('FUNCTION', 'prom_api.eq(labels1 prom_api.label_array, labels2 prom_api.label_array)')
        , ('FUNCTION', 'prom_api.eq(labels prom_api.label_array, json_labels jsonb)')
        , ('FUNCTION', 'prom_api.get_metric_metadata(metric_family_name text)')
        , ('FUNCTION', 'prom_api.get_multiple_metric_metadata(metric_families text[])')
        , ('FUNCTION', 'prom_api.is_normal_nan(value double precision)')
        , ('FUNCTION', 'prom_api.is_stale_marker(value double precision)')
        , ('FUNCTION', 'prom_api.jsonb(labels prom_api.label_array)')
        , ('FUNCTION', 'prom_api.key_value_array(labels prom_api.label_array, OUT keys text[], OUT vals text[])')
        , ('FUNCTION', 'prom_api.label_cardinality(label_id integer)')
        , ('FUNCTION', 'prom_api.label_key_position(metric_name text, key text)')
        , ('FUNCTION', 'prom_api.labels(series_id bigint)')
        , ('FUNCTION', 'prom_api.labels_info(INOUT labels integer[], OUT keys text[], OUT vals text[])')
        , ('FUNCTION', 'prom_api.matcher(labels jsonb)')
        , ('FUNCTION', 'prom_api.register_metric_view(schema_name name, view_name name, if_not_exists boolean)')
        , ('FUNCTION', 'prom_api.reset_metric_chunk_interval(metric_name text)')
        , ('FUNCTION', 'prom_api.reset_metric_compression_setting(metric_name text)')
        , ('FUNCTION', 'prom_api.reset_metric_retention_period(metric_name text)')
        , ('FUNCTION', 'prom_api.reset_metric_retention_period(schema_name text, metric_name text)')
        , ('FUNCTION', 'prom_api.set_compression_on_metric_table(metric_table_name text, compression_setting boolean)')
        , ('FUNCTION', 'prom_api.set_default_chunk_interval(chunk_interval interval)')
        , ('FUNCTION', 'prom_api.set_default_compression_setting(compression_setting boolean)')
        , ('FUNCTION', 'prom_api.set_default_retention_period(retention_period interval)')
        , ('FUNCTION', 'prom_api.set_metric_chunk_interval(metric_name text, chunk_interval interval)')
        , ('FUNCTION', 'prom_api.set_metric_compression_setting(metric_name text, new_compression_setting boolean)')
        , ('FUNCTION', 'prom_api.set_metric_retention_period(metric_name text, new_retention_period interval)')
        , ('FUNCTION', 'prom_api.set_metric_retention_period(schema_name text, metric_name text, new_retention_period interval)')
        , ('FUNCTION', 'prom_api.unregister_metric_view(schema_name name, view_name name, if_exists boolean)')
        , ('FUNCTION', 'prom_api.val(label_id integer)')
        , ('FUNCTION', 'ps_tag.tag_op_equals(_tag_key text, _value anyelement)')
        , ('FUNCTION', 'ps_tag.tag_op_equals_text(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_greater_than(_tag_key text, _value anyelement)')
        , ('FUNCTION', 'ps_tag.tag_op_greater_than_or_equal(_tag_key text, _value anyelement)')
        , ('FUNCTION', 'ps_tag.tag_op_greater_than_or_equal_text(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_greater_than_text(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_jsonb_path_exists(_tag_key text, _value jsonpath)')
        , ('FUNCTION', 'ps_tag.tag_op_less_than(_tag_key text, _value anyelement)')
        , ('FUNCTION', 'ps_tag.tag_op_less_than_or_equal(_tag_key text, _value anyelement)')
        , ('FUNCTION', 'ps_tag.tag_op_less_than_or_equal_text(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_less_than_text(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_not_equals(_tag_key text, _value anyelement)')
        , ('FUNCTION', 'ps_tag.tag_op_not_equals_text(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_regexp_matches(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_tag.tag_op_regexp_not_matches(_tag_key text, _value text)')
        , ('FUNCTION', 'ps_trace.delete_all_traces()')
        , ('FUNCTION', 'ps_trace.downstream_spans(_trace_id ps_trace.trace_id, _span_id bigint, _max_dist integer)')
        , ('FUNCTION', 'ps_trace.event_tag_type()')
        , ('FUNCTION', 'ps_trace.get_tag_map(_tags jsonb)')
        , ('FUNCTION', 'ps_trace.get_trace_retention_period()')
        , ('FUNCTION', 'ps_trace.is_event_tag_type(_tag_type ps_trace.tag_type)')
        , ('FUNCTION', 'ps_trace.is_link_tag_type(_tag_type ps_trace.tag_type)')
        , ('FUNCTION', 'ps_trace.is_resource_tag_type(_tag_type ps_trace.tag_type)')
        , ('FUNCTION', 'ps_trace.is_span_tag_type(_tag_type ps_trace.tag_type)')
        , ('FUNCTION', 'ps_trace.jsonb(_tag_map ps_trace.tag_map, VARIADIC _keys ps_trace.tag_k[])')
        , ('FUNCTION', 'ps_trace.jsonb(_tag_map ps_trace.tag_map)')
        , ('FUNCTION', 'ps_trace.link_tag_type()')
        , ('FUNCTION', 'ps_trace.operation_calls(_start_time_min timestamp with time zone, _start_time_max timestamp with time zone)')
        , ('FUNCTION', 'ps_trace.put_instrumentation_lib(_name text, _version text, _schema_url_id bigint)')
        , ('FUNCTION', 'ps_trace.put_operation(_service_name text, _span_name text, _span_kind ps_trace.span_kind)')
        , ('FUNCTION', 'ps_trace.put_schema_url(_schema_url text)')
        , ('FUNCTION', 'ps_trace.put_tag(_key ps_trace.tag_k, _value ps_trace.tag_v, _tag_type ps_trace.tag_type)')
        , ('FUNCTION', 'ps_trace.put_tag_key(_key ps_trace.tag_k, _tag_type ps_trace.tag_type)')
        , ('FUNCTION', 'ps_trace.resource_tag_type()')
        , ('FUNCTION', 'ps_trace.set_trace_retention_period(_trace_retention_period interval)')
        , ('FUNCTION', 'ps_trace.sibling_spans(_trace_id ps_trace.trace_id, _span_id bigint)')
        , ('FUNCTION', 'ps_trace.span_tag_type()')
        , ('FUNCTION', 'ps_trace.span_tree(_trace_id ps_trace.trace_id, _span_id bigint, _max_dist integer)')
        , ('FUNCTION', 'ps_trace.trace_tree(_trace_id ps_trace.trace_id)')
        , ('FUNCTION', 'ps_trace.upstream_spans(_trace_id ps_trace.trace_id, _span_id bigint, _max_dist integer)')
        , ('FUNCTION', 'ps_trace.val(_tag_map ps_trace.tag_map, _key ps_trace.tag_k)')
        , ('FUNCTION', 'ps_trace.val_text(_tag_map ps_trace.tag_map, _key ps_trace.tag_k)')
        , ('PROCEDURE', '_prom_catalog.compress_metric_chunks(IN metric_name text)')
        , ('PROCEDURE', '_prom_catalog.compress_old_chunks(IN metric_table text, IN compress_before timestamp with time zone)')
        , ('PROCEDURE', '_prom_catalog.decompress_chunks_after(IN metric_table name, IN min_time timestamp with time zone, IN transactional boolean)')
        , ('PROCEDURE', '_prom_catalog.do_decompress_chunks_after(IN metric_table name, IN min_time timestamp with time zone, IN transactional boolean)')
        , ('PROCEDURE', '_prom_catalog.drop_metric_chunks(IN schema_name text, IN metric_name text, IN older_than timestamp with time zone, IN ran_at timestamp with time zone, IN log_verbose boolean)')
        , ('PROCEDURE', '_prom_catalog.execute_compression_policy(IN log_verbose boolean)')
        , ('PROCEDURE', '_prom_catalog.execute_data_retention_policy(IN log_verbose boolean)')
        , ('PROCEDURE', '_prom_catalog.execute_everywhere(IN command_key text, IN command text, IN transactional boolean)')
        , ('PROCEDURE', '_prom_catalog.execute_maintenance_job(IN job_id integer, IN config jsonb)')
        , ('PROCEDURE', '_prom_catalog.finalize_metric_creation()')
        , ('PROCEDURE', '_prom_catalog.update_execute_everywhere_entry(IN command_key text, IN command text, IN transactional boolean)')
        , ('PROCEDURE', '_ps_trace.drop_event_chunks(IN _older_than timestamp with time zone)')
        , ('PROCEDURE', '_ps_trace.drop_link_chunks(IN _older_than timestamp with time zone)')
        , ('PROCEDURE', '_ps_trace.drop_span_chunks(IN _older_than timestamp with time zone)')
        , ('PROCEDURE', '_ps_trace.execute_data_retention_policy(IN log_verbose boolean)')
        , ('PROCEDURE', 'prom_api.add_prom_node(IN node_name text, IN attach_to_existing_metrics boolean)')
        , ('PROCEDURE', 'prom_api.execute_maintenance(IN log_verbose boolean)')
        , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_regexp_matches)')
        , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_not_equals)')
        , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_equals)')
        , ('OPERATOR', '_prom_catalog.?(prom_api.label_array, ps_tag.tag_op_regexp_not_matches)')
        , ('OPERATOR', 'prom_api.?(prom_api.label_array, prom_api.matcher_positive)')
        , ('OPERATOR', 'prom_api.?(prom_api.label_array, prom_api.matcher_negative)')
        , ('OPERATOR', 'prom_api.@>(prom_api.label_value_array, pg_catalog.text)')
        , ('OPERATOR', 'prom_api.@>(prom_api.label_array, pg_catalog.jsonb)')
        , ('OPERATOR', 'ps_tag.!==(pg_catalog.text, pg_catalog.anyelement)')
        , ('OPERATOR', 'ps_tag.!==(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.!=~(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.#<(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.#<(pg_catalog.text, pg_catalog.anyelement)')
        , ('OPERATOR', 'ps_tag.#<=(pg_catalog.text, pg_catalog.anyelement)')
        , ('OPERATOR', 'ps_tag.#<=(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.#>(pg_catalog.text, pg_catalog.anyelement)')
        , ('OPERATOR', 'ps_tag.#>(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.#>=(pg_catalog.text, pg_catalog.anyelement)')
        , ('OPERATOR', 'ps_tag.#>=(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.==(pg_catalog.text, pg_catalog.anyelement)')
        , ('OPERATOR', 'ps_tag.==(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.==~(pg_catalog.text, pg_catalog.text)')
        , ('OPERATOR', 'ps_tag.@?(pg_catalog.text, pg_catalog.jsonpath)')
        , ('OPERATOR', 'ps_trace.#(ps_trace.tag_map, ps_trace.tag_k)')
        , ('OPERATOR', 'ps_trace.#?(ps_trace.tag_map, ps_trace.tag_k)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_not_equals)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_less_than)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_less_than_or_equal)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_greater_than)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_greater_than_or_equal)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_equals)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_regexp_not_matches)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_regexp_matches)')
        , ('OPERATOR', 'ps_trace.?(ps_trace.tag_map, ps_tag.tag_op_jsonb_path_exists)')
        ) x(objtype, objname)
    )
    LOOP
        EXECUTE format('ALTER EXTENSION promscale ADD %s %s', _rec.objtype, _rec.objname);
        EXECUTE format('ALTER %s %s OWNER TO %I', _rec.objtype, _rec.objname, current_user);

        IF _rec.objtype IN ('TABLE', 'SEQUENCE') AND _rec.objname NOT IN ('_ps_catalog.migration', '_ps_catalog.promscale_instance_information') THEN
            _config_filter = case _rec.objname
                when '_prom_catalog.remote_commands' then 'where seq >= 1000'
                when '_ps_trace.tag_key' then 'where id >= 1000'
                else ''
            end;
            EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump(%L, %L)$sql$, _rec.objname, _config_filter);
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
        EXECUTE format($sql$ALTER TABLE _ps_trace.tag_%s OWNER TO %I$sql$, _i, current_user);
        EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump('_ps_trace.tag_%s', '')$sql$, _i);
   END LOOP;
END
$block$
;

-- metric tables / views
DO $block$
DECLARE
    _rec record;
BEGIN
    FOR _rec IN
    (
        SELECT m.*
        FROM _prom_catalog.metric m
        WHERE table_schema = 'prom_data'
        ORDER BY m.table_schema, m.table_name
    )
    LOOP
        EXECUTE format($sql$ALTER TABLE %I.%I OWNER TO prom_admin $sql$, _rec.table_schema, _rec.table_name);
        EXECUTE format($sql$ALTER TABLE prom_data_series.%I OWNER TO prom_admin $sql$, _rec.series_table);
        EXECUTE format($sql$ALTER VIEW prom_series.%I OWNER TO prom_admin $sql$, _rec.series_table);
        EXECUTE format($sql$ALTER VIEW prom_metric.%I OWNER TO prom_admin $sql$, _rec.table_name);
   END LOOP;
END
$block$;

-- exemplar tables
 DO $block$
 DECLARE
     _rec record;
 BEGIN
     FOR _rec IN
     (
         SELECT e.table_name
         FROM _prom_catalog.exemplar e
         ORDER BY e.table_name
     )
     LOOP
         EXECUTE format($sql$ALTER TABLE prom_data_exemplar.%I OWNER TO prom_admin $sql$, _rec.table_name);
     END LOOP;
 END;
 $block$
 ;

 -- migration table
DO $block$
BEGIN
    CREATE TABLE _ps_catalog.migration(
      name TEXT NOT NULL PRIMARY KEY
    , applied_at_version TEXT
    , body TEXT
    , applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT clock_timestamp()
    );
    CREATE UNIQUE INDEX ON _ps_catalog.migration(name);
    PERFORM pg_catalog.pg_extension_config_dump('_ps_catalog.migration', '');

    -- Bring migrations table up to speed
    INSERT INTO _ps_catalog.migration (name, applied_at_version)
    VALUES
        ('001-create-ext-schema.sql'      , '0.0.0'),
        ('001-extension.sql'              , '0.0.0'),
        ('002-utils.sql'                  , '0.0.0'),
        ('003-users.sql'                  , '0.0.0'),
        ('004-schemas.sql'                , '0.0.0'),
        ('005-tag-operators.sql'          , '0.0.0'),
        ('006-tables.sql'                 , '0.0.0'),
        ('007-matcher-operators.sql'      , '0.0.0'),
        ('008-install-uda.sql'            , '0.0.0'),
        ('009-tables-ha.sql'              , '0.0.0'),
        ('010-tables-metadata.sql'        , '0.0.0'),
        ('011-tables-exemplar.sql'        , '0.0.0'),
        ('012-tracing.sql'                , '0.0.0'),
        ('013-tracing-well-known-tags.sql', '0.0.0'),
        ('014-telemetry.sql'              , '0.0.0')
    ;
END
$block$
;

-- Duplicates a section of 003-users
CALL _prom_catalog.execute_everywhere('grant_all_roles_to_extowner',
format(
$ee$
    DO $$
    BEGIN
        GRANT prom_reader TO %1$I WITH ADMIN OPTION;
        GRANT prom_writer TO %1$I WITH ADMIN OPTION;
        GRANT prom_maintenance TO %1$I WITH ADMIN OPTION;
        GRANT prom_modifier TO %1$I WITH ADMIN OPTION;
        GRANT prom_admin TO %1$I WITH ADMIN OPTION;
    END
    $$;
$ee$, session_user
)
);

-- The contents of this file was auto-generated by the pgx extension, but was
-- placed here manually

-- src/aggregates/gapfill_delta.rs:29
-- promscale::aggregates::gapfill_delta::GapfillDeltaTransition
CREATE TYPE _prom_ext.GapfillDeltaTransition;

-- src/aggregates/gapfill_delta.rs:29
-- promscale::aggregates::gapfill_delta::gapfilldeltatransition_in
CREATE FUNCTION _prom_ext."gapfilldeltatransition_in"(
	"input" cstring /* &cstr_core::CStr */
) RETURNS _prom_ext.GapfillDeltaTransition /* promscale::aggregates::gapfill_delta::GapfillDeltaTransition */
IMMUTABLE PARALLEL SAFE STRICT
LANGUAGE c /* Rust */
AS '$libdir/promscale-0.5.0', 'gapfilldeltatransition_in_wrapper';

-- src/aggregates/gapfill_delta.rs:29
-- promscale::aggregates::gapfill_delta::gapfilldeltatransition_out
CREATE FUNCTION _prom_ext."gapfilldeltatransition_out"(
	"input" _prom_ext.GapfillDeltaTransition /* promscale::aggregates::gapfill_delta::GapfillDeltaTransition */
) RETURNS cstring /* &cstr_core::CStr */
IMMUTABLE PARALLEL SAFE STRICT
LANGUAGE c /* Rust */
AS '$libdir/promscale-0.5.0', 'gapfilldeltatransition_out_wrapper';

-- src/aggregates/gapfill_delta.rs:29
-- promscale::aggregates::gapfill_delta::GapfillDeltaTransition
CREATE TYPE _prom_ext.GapfillDeltaTransition (
	INTERNALLENGTH = variable,
	INPUT = _prom_ext.gapfilldeltatransition_in, /* promscale::aggregates::gapfill_delta::gapfilldeltatransition_in */
	OUTPUT = _prom_ext.gapfilldeltatransition_out, /* promscale::aggregates::gapfill_delta::gapfilldeltatransition_out */
	STORAGE = extended
);



--make sure the objects that we have made part of the extension are secure
DO $block$
DECLARE
    obj_owner_oid oid;
    is_super boolean;
    errors text[];
BEGIN
    --the owner of extension objects is whoever is executing this script
    SELECT usesysid INTO STRICT obj_owner_oid FROM pg_user WHERE usename = current_user;

    --figure out if whoever is executing the extension is a superuser;
    --use session and not current user to be compatible with pgextwlist
    --namely, we want to check the user installing the extension, not whoever
    --is running this script because pgextwlist would make that the bootstrap superuser.
    --note that @ext_owner@ is also changed to superuser under pgextwlist (even if trusted extension).
    --in general, it seems using the session_user is safer than other alternatives.
    SELECT usesuper INTO STRICT is_super FROM pg_user WHERE usename = session_user;

    --way out of these checks for superusers
    IF NOT (is_super AND coalesce(current_setting('promscale.disable_security_check', true)::boolean, false))
    THEN
        --the basic approach here is find all objects depending on our extension and make sure they have the right owner
        --the first query handles most types of object but some objects need special handling.
        --those can be found further down.

        --this code does not need to say "ok" to all types of objects, just those that exists in the connector 0.10.0
        --schema. On the other hand it /must/ fail all other objects.
        with recursive cte AS (
            select
                    0 as level,
                    ARRAY[pg_describe_object(classid, objid, objsubid)] descr,
                false is_cycle,
                classid,
                objid,
                objsubid
            from pg_depend
            where deptype='e' and
                refclassid='pg_catalog.pg_extension'::regclass and
                refobjid = (select oid from pg_extension where extname='promscale')
            UNION ALL
            select
                level + 1,
                cte.descr || pg_describe_object(dep.classid, dep.objid, dep.objsubid),
                pg_describe_object(dep.classid, dep.objid, dep.objsubid) = ANY(descr),
                dep.classid,
                dep.objid,
                dep.objsubid
            from cte
            inner join pg_depend dep ON (cte.classid = dep.refclassid
                                    AND cte.objid = dep.refobjid)
            where NOT is_cycle
        ),
        with_owner as (
            SELECT
                CASE
                WHEN classid = 'pg_class'::regclass THEN
                    (select relowner from pg_class where oid = objid)
                WHEN classid = 'pg_type'::regclass THEN
                    (select typowner from pg_type where oid = objid)
                WHEN classid = 'pg_proc'::regclass THEN
                    (select proowner from pg_proc where oid = objid)
                WHEN classid = 'pg_namespace'::regclass THEN
                    (select nspowner from pg_namespace where oid = objid)
                WHEN classid = 'pg_operator'::regclass THEN
                    (select oprowner from pg_operator where oid = objid)
                ELSE
                    -1
                END as owner,
                *
            FROM cte
            --each of these classes is handled separately below
            WHERE classid NOT IN (
                'pg_constraint'::regclass,
                'pg_trigger'::regclass,
                'pg_rewrite'::regclass,
                'pg_attrdef'::regclass
            )
        )
        select array_agg (
                'Object ' || pg_describe_object(classid, objid, objsubid) || ' is owned by ' || owner::text
        )
        into errors
        from with_owner
        where (
            --either the owner is the object owner
            (owner = obj_owner_oid)
            OR
            --or prom_admin (these are for metric and series tables)
            (owner = (SELECT oid FROM pg_roles WHERE rolname = 'prom_admin') AND classid IN ('pg_class'::regclass, 'pg_type'::regclass))
        ) is not true;

        IF array_length(errors, 1) > 0 THEN
            RAISE EXCEPTION 'could not secure the promscale installation: %', array_to_string(errors, ', ');
        END IF;

        --check constraints: make sure all check constraints use expressions recognized by us
        with recursive cte AS (
            select
                    0 as level,
                    ARRAY[pg_describe_object(classid, objid, objsubid)] descr,
                false is_cycle,
                classid,
                objid,
                objsubid
            from pg_depend
            where deptype='e' and
                refclassid='pg_catalog.pg_extension'::regclass and
                refobjid = (select oid from pg_extension where extname='promscale')
            UNION ALL
            select
                level + 1,
                cte.descr || pg_describe_object(dep.classid, dep.objid, dep.objsubid),
                pg_describe_object(dep.classid, dep.objid, dep.objsubid) = ANY(descr),
                dep.classid,
                dep.objid,
                dep.objsubid
            from cte
            inner join pg_depend dep ON (cte.classid = dep.refclassid
                                    AND cte.objid = dep.refobjid)
            where NOT is_cycle
        ),
        constr as (
            SELECT *
            FROM cte
            INNER JOIN pg_constraint c ON (
                    cte.classid = 'pg_constraint'::regclass AND
                    c.oid = cte.objid)
            WHERE c.contype NOT IN ('f','p','u') --fk, pk, and unique are safe
        )
        select array_agg (
                'constraint ' || pg_describe_object(classid, objid, objsubid) || ' has unrecognized check constraint ' || pg_get_constraintdef(oid)
        )
        into errors
        FROM constr
        WHERE ( --if the part inside the parenthesis returns true, the constraint is safe
        pg_get_constraintdef(oid) = ANY(
            $${
            "CHECK ((VALUE <> ''::text))",
            "CHECK ((jsonb_typeof(VALUE) = 'object'::text))",
            "CHECK ((VALUE <> '00000000-0000-0000-0000-000000000000'::uuid))",
            "CHECK ((VALUE <> '00000000-0000-0000-0000-000000000000'::uuid))",
            "CHECK ((VALUE <> ''::text))",
            "CHECK ((jsonb_typeof(VALUE) = 'object'::text))",
            "CHECK ((is_unique = true))",
            "CHECK ((id > 0))",
            "CHECK ((((uuid = '00000000-0000-0000-0000-000000000000'::uuid) OR (NOT is_counter_reset_row)) AND ((uuid <> '00000000-0000-0000-0000-000000000000'::uuid) OR is_counter_reset_row)))",
            "CHECK ((span_id <> 0))",
            "CHECK ((linked_span_id <> 0))",
            "CHECK ((parent_span_id <> 0))",
            "CHECK ((span_name <> ''::text))",
            "CHECK ((start_time <= end_time))",
            "CHECK ((trace_state <> ''::text))",
            "CHECK ((url <> ''::text))"
            }$$::text[]
        )
        OR
        pg_get_constraintdef(oid) similar to 'CHECK \(\(metric_id = \d*\)\)'
        OR
        pg_get_constraintdef(oid) similar to 'CHECK \(\(\(labels\[1\] = \d*\) AND \(labels\[1\] IS NOT NULL\)\)\)'
        OR
        pg_get_constraintdef(oid) similar to $$CHECK \(\(\("time" >= '(\d|\-| |\.|\:|\+)*'::timestamp with time zone\) AND \("time" < '(\d|\-| |\.|\:|\+)*'::timestamp with time zone\)\)\)$$
        OR
        pg_get_constraintdef(oid) similar to $$CHECK \(\(\(start_time >= '(\d|\-| |\.|\:|\+)*'::timestamp with time zone\) AND \(start_time < '(\d|\-| |\.|\:|\+)*'::timestamp with time zone\)\)\)$$
        OR
        pg_get_constraintdef(oid) similar to $$CHECK \(\(\(span_start_time >= '(\d|\-| |\.|\:|\+)*'::timestamp with time zone\) AND \(span_start_time < '(\d|\-| |\.|\:|\+)*'::timestamp with time zone\)\)\)$$
        ) IS NOT TRUE; --use is not true for correct NULL handling

        IF array_length(errors, 1) > 0 THEN
            RAISE EXCEPTION 'could not secure the promscale installation: %', array_to_string(errors, ', ');
        END IF;

        --triggers: make sure associated functions owned by us or a superuser (superuser own fk triggers, cont agg triggers)
        with recursive cte AS (
            select
                    0 as level,
                    ARRAY[pg_describe_object(classid, objid, objsubid)] descr,
                false is_cycle,
                classid,
                objid,
                objsubid
            from pg_depend
            where deptype='e' and
                refclassid='pg_catalog.pg_extension'::regclass and
                refobjid = (select oid from pg_extension where extname='promscale')
            UNION ALL
            select
                level + 1,
                cte.descr || pg_describe_object(dep.classid, dep.objid, dep.objsubid),
                pg_describe_object(dep.classid, dep.objid, dep.objsubid) = ANY(descr),
                dep.classid,
                dep.objid,
                dep.objsubid
            from cte
            inner join pg_depend dep ON (cte.classid = dep.refclassid
                                    AND cte.objid = dep.refobjid)
            where NOT is_cycle
        ),
        trigger as (
            SELECT *
            FROM cte
            INNER JOIN pg_trigger t ON (
                    cte.classid = 'pg_trigger'::regclass AND
                    t.oid = cte.objid)
            LEFT JOIN pg_proc p ON (p.oid = t.tgfoid)
            LEFT JOIN pg_authid a ON (p.proowner = a.oid)
        )
        SELECT array_agg (
                'Trigger ' || pg_describe_object(classid, objid, objsubid) || ' is owned by ' || t.proowner::text
                )
        INTO errors
        FROM trigger t
        WHERE t.proowner != obj_owner_oid and not t.rolsuper;

        IF array_length(errors, 1) > 0 THEN
            RAISE EXCEPTION 'could not secure the promscale installation: %', array_to_string(errors, ', ');
        END IF;

        --rewrite rules must refer to views owned by us
        with recursive cte AS (
            select
                    0 as level,
                    ARRAY[pg_describe_object(classid, objid, objsubid)] descr,
                false is_cycle,
                classid,
                objid,
                objsubid,
                refclassid,
                refobjid,
                refobjsubid
            from pg_depend
            where deptype='e' and
                refclassid='pg_catalog.pg_extension'::regclass and
                refobjid = (select oid from pg_extension where extname='promscale')
            UNION ALL
            select
                level + 1,
                cte.descr || pg_describe_object(dep.classid, dep.objid, dep.objsubid),
                pg_describe_object(dep.classid, dep.objid, dep.objsubid) = ANY(descr),
                dep.classid,
                dep.objid,
                dep.objsubid,
                dep.refclassid,
                dep.refobjid,
                dep.refobjsubid
            from cte
            inner join pg_depend dep ON (cte.classid = dep.refclassid
                                    AND cte.objid = dep.refobjid)
            where NOT is_cycle
        ),
        rewrite as (
            SELECT *
            FROM cte
            INNER JOIN pg_rewrite r ON (
                    cte.classid = 'pg_rewrite'::regclass AND
                    r.oid = cte.objid)
            LEFT JOIN pg_class c ON (r.ev_class = c.oid)
        )
        SELECT array_agg (
                'rewrite rule ' || pg_describe_object(classid, objid, objsubid) || ' is owned by ' || relowner::text
        )
        INTO errors
        FROM rewrite
        WHERE ( --if the part inside the parenthesis returns true, the rewrite is safe
            --views owned by us are safe
            (relowner = obj_owner_oid and relkind = 'v' and rulename='_RETURN')
            OR
            --views owned by prom_admin are safe (these are metric and series views)
            (relowner = (SELECT oid FROM pg_roles WHERE rolname = 'prom_admin') and relkind = 'v' and rulename='_RETURN')
            OR
            --views using our functions are safe (probably in user-defined views)
            (refclassid = 'pg_proc'::regclass)
            OR
            --column references are safe (probably in user-defined views)
            (refclassid = 'pg_class'::regclass AND refobjsubid != 0)
        ) IS NOT TRUE; --use "is not true" for correct NULL handling

        IF array_length(errors, 1) > 0 THEN
            RAISE EXCEPTION 'could not secure the promscale installation: %', array_to_string(errors, ', ');
        END IF;

        --all column defaults refer to sequences owned by us or known values
        with recursive cte AS (
            select
                    0 as level,
                    ARRAY[pg_describe_object(classid, objid, objsubid)] descr,
                false is_cycle,
                classid,
                objid,
                objsubid
            from pg_depend
            where deptype='e' and
                refclassid='pg_catalog.pg_extension'::regclass and
                refobjid = (select oid from pg_extension where extname='promscale')
            UNION ALL
            select
                level + 1,
                cte.descr || pg_describe_object(dep.classid, dep.objid, dep.objsubid),
                pg_describe_object(dep.classid, dep.objid, dep.objsubid) = ANY(descr),
                dep.classid,
                dep.objid,
                dep.objsubid
            from cte
            inner join pg_depend dep ON (cte.classid = dep.refclassid
                                    AND cte.objid = dep.refobjid)
            where NOT is_cycle
        ),
        attrdef as (
            SELECT pg_get_expr(adbin, adrelid) expr, cte.*, upstream_seq_class.relowner as seq_owner
            FROM cte
            INNER JOIN pg_attrdef a ON (
                    cte.classid = 'pg_attrdef'::regclass AND
                    a.oid = cte.objid)
            LEFT JOIN pg_depend upstream_seq ON (
                    upstream_seq.objid = a.oid AND
                    upstream_seq.classid = 'pg_attrdef'::regclass AND
                    upstream_seq.refclassid = 'pg_class'::regclass AND
                    (SELECT relkind = 'S' FROM pg_class c WHERE c.oid=upstream_seq.refobjid)
            )
            LEFT JOIN pg_class upstream_seq_class ON (
                upstream_seq_class.oid = upstream_seq.refobjid
            )
        )
        SELECT array_agg (
                'attribute default ' || pg_describe_object(classid, objid, objsubid) || ' is unrecognized: ' || expr
        )
        INTO errors
        FROM attrdef
        WHERE ( --if the part in the parenthesis returns true it means the default is safe
            --sequeneces owned by the owner are safe
            (seq_owner is not null and seq_owner = obj_owner_oid)
            OR
            --known expressions are good
            (expr = ANY(
                    $${
                    "'prom_data'::name",
                    "(EXTRACT(epoch FROM (end_time - start_time)) * 1000.0)",
                    "(date_part('epoch'::text, (end_time - start_time)) * (1000.0)::double precision)",
                    "0",
                    "clock_timestamp()",
                    "false",
                    "true"
                    }$$::text[]
               )
            )
        ) IS NOT TRUE; --use "is not true" for correct NULL handling

        IF array_length(errors, 1) > 0 THEN
            RAISE EXCEPTION 'could not secure the promscale installation: %', array_to_string(errors, ', ');
        END IF;
    END IF;
END
$block$;