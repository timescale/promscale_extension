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
select * from _ps_trace.schema_url;
select ps_trace.put_instrumentation_lib('test-inst-lib-1', '9.9.9', ps_trace.put_schema_url('buz.bam.bip'));
select ps_trace.put_operation('test-service-1', 'endpoint-1', 'SPAN_KIND_SERVER'::ps_trace.span_kind);
