\set ECHO all
\set ON_ERROR_STOP 1

CREATE EXTENSION promscale;

-- We don't want retention to mess with the test data
SELECT ps_trace.set_trace_retention_period('100 years'::INTERVAL);

CREATE FUNCTION assert(assertion BOOLEAN, msg TEXT)
    RETURNS BOOLEAN
    LANGUAGE plpgsql VOLATILE AS
$fnc$
BEGIN
    ASSERT assertion, msg;
    RETURN assertion;
END;
$fnc$;

SELECT put_tag('service.namespace', gen.kilobytes_of_garbage::jsonb, resource_tag_type())
	FROM (
		SELECT repeat('1', 3000) AS kilobytes_of_garbage
	) AS gen;

SELECT 
  assert(length(value::text) > 2704,
   'tag value is indeed larger than btree''s version 4 maximum row size for an index'
  )
FROM _ps_trace.tag t WHERE t.key = 'service.namespace';

SELECT put_tag('service.namespace', '"testvalue"', resource_tag_type()) AS t1;
\gset
SELECT put_tag('faas.name', '"testvalue"', resource_tag_type()) AS t2;
\gset
SELECT assert(:t1 != :t2, 'tag ids must be distinct when tag keys are');

SELECT put_tag('service.namespace', '{"testvalue": 1}'::jsonb, resource_tag_type()) AS t1;
\gset
SELECT put_tag('service.namespace', '{"testvalue": 2}'::jsonb, resource_tag_type()) AS t2;
\gset
SELECT assert(:t1 != :t2, 'tag ids must be distinct when tag values are');

SELECT put_operation('myservice', 'test', 'unspecified') AS op_tag_id;
\gset
SELECT put_tag('service.name', '"myservice"'::jsonb, resource_tag_type()) AS srvc_tag_id;
\gset

SELECT id AS op_tag_id_stored
  FROM _ps_trace.operation
    WHERE span_kind = 'unspecified'
      AND span_name = 'test'
      AND service_name_id = :srvc_tag_id;
\gset

SELECT assert(:op_tag_id_stored = :op_tag_id, 'operation lookup by tag id must return the same tag');

SELECT put_tag('host.name', '"foobar"'::jsonb, resource_tag_type()) AS host_tag_id;
\gset

SELECT assert(
	get_tag_map(('{"host.name": "foobar", "service.name": "myservice"}')::jsonb)::jsonb
	= 
	jsonb_build_object('1', :srvc_tag_id, '33', :host_tag_id),
	'get tag map must produce the expected result'
);

SELECT _ps_trace.tag_v_eq_matching_tags('service.name', '"myservice"'::jsonb);