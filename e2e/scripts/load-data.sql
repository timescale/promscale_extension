/*
This script creates the promscale extension in the database and then
adds metric, exemplar, and trace data to the database so that the
dump/restore process has more to work with than simply the empty
data structures
*/
SELECT _prom_catalog.set_default_value('ha_lease_timeout'::text, '200 hours'::text);

SELECT _prom_catalog.get_or_create_metric_table_name('cpu_usage');
SELECT _prom_catalog.get_or_create_metric_table_name('cpu_usage_no_compression');
SELECT _prom_catalog.get_or_create_metric_table_name('cpu_total');
CALL _prom_catalog.finalize_metric_creation();

SELECT set_compression_on_metric_table('cpu_usage_no_compression', false);

INSERT INTO prom_data.cpu_usage
SELECT timestamptz '2030-01-01 02:03:04'+(interval '1s' * g), 100.1 + g, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_usage", "namespace":"dev", "node": "brain"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_usage
SELECT timestamptz '2030-01-01 02:03:04'+(interval '1s' * g), 100.1 + g, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_usage", "namespace":"production", "node": "pinky", "new_tag":"foo"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_usage_no_compression
SELECT timestamptz '2030-01-01 02:03:04'+(interval '1s' * g), 100.1 + g, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_usage_no_compression", "namespace":"production", "node": "pinky", "new_tag":"foo"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_total
SELECT timestamptz '2030-01-01 02:03:04'+(interval '1s' * g), 100.0, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_total", "namespace":"dev", "node": "brain"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_total
SELECT timestamptz '2030-01-01 02:03:04'+(interval '1s' * g), 100.0, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_total", "namespace":"production", "node": "pinky", "new_tag_2":"bar"}')
FROM generate_series(1,10) g;

-- compress chunks for one of the metrics
SELECT public.compress_chunk(public.show_chunks('prom_data.cpu_usage'));

select _prom_catalog.create_exemplar_table_if_not_exists('cpu_total');

select _prom_catalog.insert_exemplar_row
( 'cpu_total'::text
, array['2030-01-01 02:03:04'::timestamptz]
, array[3::bigint]
, array[array['cpu_total', 'dev', 'brain']::label_value_array]
, array[42::double precision]
);

select ps_trace.put_tag_key('test-tag-0', ps_trace.span_tag_type());
select ps_trace.put_tag_key('test-tag-1', ps_trace.span_tag_type());
select ps_trace.put_tag('test-tag-0', to_jsonb(0), ps_trace.span_tag_type());
select ps_trace.put_tag('test-tag-1', to_jsonb(1), ps_trace.span_tag_type());
select ps_trace.put_instrumentation_lib('test-inst-lib-0', '9.9.9', ps_trace.put_schema_url('foo.bar.baz'));
select ps_trace.put_operation('test-service-0', 'endpoint-0', 'server'::ps_trace.span_kind);

insert into _ps_trace.span
( trace_id
, span_id
, parent_span_id
, operation_id
, start_time
, end_time
, duration_ms
, trace_state
, span_tags
, dropped_tags_count
, event_time
, dropped_events_count
, dropped_link_count
, status_code
, status_message
, instrumentation_lib_id
, resource_tags
, resource_dropped_tags_count
, resource_schema_url_id
) values
( 'd43807ea-b28c-4587-8f50-373d9a04ce16'::ps_trace.trace_id
, 123456
, null
, 1
, '2030-01-06 01:02'::timestamptz
, '2030-01-06 01:03'::timestamptz
, extract(epoch from ('2030-01-06 01:03'::timestamptz - '2030-01-06 01:02'::timestamptz)) * 1000
, 'TEST'
, ps_trace.get_tag_map(jsonb_build_object('test-tag-0', to_jsonb(0), 'test-tag-1', to_jsonb(1)))
, 1
, tstzrange('2030-01-06 01:02'::timestamptz, '2030-01-06 01:03'::timestamptz, '[)')
, 2
, 3
, 'ok'::ps_trace.status_code
, 'OK'
, 1
, ps_trace.get_tag_map(jsonb_build_object('test-tag-1', to_jsonb(1)))
, 4
, 1
),
( 'd43807ea-b28c-4587-8f50-373d9a04ce16'::ps_trace.trace_id
, 654321
, 123456
, 1
, '2030-01-06 01:02'::timestamptz
, '2030-01-06 01:03'::timestamptz
, extract(epoch from ('2030-01-06 01:03'::timestamptz - '2030-01-06 01:02'::timestamptz)) * 1000
, 'TEST'
, ps_trace.get_tag_map(jsonb_build_object('test-tag-0', to_jsonb(0), 'test-tag-1', to_jsonb(1)))
, 1
, tstzrange('2030-01-06 01:02'::timestamptz, '2030-01-06 01:03'::timestamptz, '[)')
, 2
, 3
, 'ok'::ps_trace.status_code
, 'OK'
, 1
, ps_trace.get_tag_map(jsonb_build_object('test-tag-1', to_jsonb(1)))
, 4
, 1
);

INSERT INTO _ps_trace.event
( time
, trace_id
, span_id
, event_nbr
, name
, tags
, dropped_tags_count
) VALUES
( '2030-01-06 01:02:03'::timestamptz
, 'd43807ea-b28c-4587-8f50-373d9a04ce16'::ps_trace.trace_id
, 654321
, 1
, 'this is a test event'
, ps_trace.get_tag_map(jsonb_build_object('test-tag-1', to_jsonb(1)))
, 0
);

INSERT INTO _ps_trace.link
( trace_id
, span_id
, span_start_time
, linked_trace_id
, linked_span_id
, link_nbr
, trace_state
, tags
, dropped_tags_count
) VALUES
( 'd43807ea-b28c-4587-8f50-373d9a04ce16'::ps_trace.trace_id
, 654321
, '2030-01-06 01:02'::timestamptz
, 'd43807ea-b28c-4587-8f50-373d9a04ce16'::ps_trace.trace_id
, 123456
, 1
, 'OK'
, ps_trace.get_tag_map(jsonb_build_object('test-tag-0', to_jsonb(0), 'test-tag-1', to_jsonb(1)))
, 0
);
