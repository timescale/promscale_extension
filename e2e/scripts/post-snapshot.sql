\set VERBOSITY verbose

INSERT INTO prom_data.cpu_usage
SELECT timestamptz '2030-01-02 02:03:04'+(interval '1s' * g), 100.1 + g, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_usage", "namespace":"dev", "node": "brain"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_usage
SELECT timestamptz '2030-01-02 02:03:04'+(interval '1s' * g), 100.1 + g, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_usage", "namespace":"production", "node": "pinky", "new_tag":"foo"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_total
SELECT timestamptz '2030-01-02 02:03:04'+(interval '1s' * g), 100.0, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_total", "namespace":"dev", "node": "brain"}')
FROM generate_series(1,10) g;
INSERT INTO prom_data.cpu_total
SELECT timestamptz '2030-01-02 02:03:04'+(interval '1s' * g), 100.0, _prom_catalog.get_or_create_series_id('{"__name__": "cpu_total", "namespace":"production", "node": "pinky", "new_tag_2":"bar"}')
FROM generate_series(1,10) g;

select ps_trace.put_tag_key('test-tag-2', ps_trace.span_tag_type());
select ps_trace.put_tag_key('test-tag-3', ps_trace.span_tag_type());
select ps_trace.put_tag('test-tag-2', to_jsonb(2), ps_trace.span_tag_type());
select ps_trace.put_tag('test-tag-3', to_jsonb(3), ps_trace.span_tag_type());
select ps_trace.put_instrumentation_lib('test-inst-lib-1', '9.9.9', ps_trace.put_schema_url('buz.bam.bip'));
select ps_trace.put_operation('test-service-1', 'endpoint-1', 'SPAN_KIND_SERVER'::ps_trace.span_kind);

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
( 'd7d6d485-0470-4e88-86af-8e512e3be557'::ps_trace.trace_id
, 987654
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
, 'STATUS_CODE_OK'::ps_trace.status_code
, 'OK'
, 1
, ps_trace.get_tag_map(jsonb_build_object('test-tag-1', to_jsonb(1)))
, 4
, 1
),
( 'd7d6d485-0470-4e88-86af-8e512e3be557'::ps_trace.trace_id
, 456789
, 987654
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
, 'STATUS_CODE_OK'::ps_trace.status_code
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
, 'd7d6d485-0470-4e88-86af-8e512e3be557'::ps_trace.trace_id
, 456789
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
( 'd7d6d485-0470-4e88-86af-8e512e3be557'::ps_trace.trace_id
, 456789
, '2030-01-06 01:02'::timestamptz
, 'd43807ea-b28c-4587-8f50-373d9a04ce16'::ps_trace.trace_id
, 123456
, 1
, 'OK'
, ps_trace.get_tag_map(jsonb_build_object('test-tag-0', to_jsonb(0), 'test-tag-1', to_jsonb(1)))
, 0
);
