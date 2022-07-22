\unset ECHO
\set QUIET 1
\i '/testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(16);

CREATE EXTENSION promscale;

INSERT INTO _ps_trace.schema_url (url)
VALUES ('fake.url.com');

INSERT INTO _ps_trace.instrumentation_lib (name, version, schema_url_id)
    (
        SELECT 'inst_lib_1', '1.0.0', id
        FROM _ps_trace.schema_url
        WHERE url = 'fake.url.com'
        LIMIT 1
    );

SELECT ps_trace.put_operation('my.service.name', 'my.span.name', 'unspecified');

SELECT ps_trace.put_tag_key('my.tag.key', 1::ps_trace.tag_type);

SELECT ps_trace.put_tag('my.tag.key', 'true'::jsonb, 1::ps_trace.tag_type);

INSERT INTO _ps_trace.span
(trace_id, span_id, parent_span_id, operation_id, start_time, end_time, duration_ms, span_tags, status_code,
 resource_tags, resource_schema_url_id)
VALUES ('3dadb2bf-0035-433e-b74b-9075cc9260e8',
        1234,
        null,
        -1,
        now(),
        now(),
        0,
        '{}'::jsonb::tag_map,
        'ok',
        '{}'::jsonb::tag_map,
        -1);

INSERT INTO _ps_trace.link
(trace_id, span_id, span_start_time, linked_trace_id, linked_span_id, link_nbr, trace_state,
 tags, dropped_tags_count)
SELECT s.trace_id,
       s.span_id,
       s.start_time,
       s.trace_id,
       s.span_id,
       1,
       'OK',
       '{}'::jsonb::tag_map,
       0
FROM _ps_trace.span s;

INSERT INTO _ps_trace.event
(time, trace_id, span_id, event_nbr, name, tags, dropped_tags_count)
SELECT now(),
       s.trace_id,
       s.span_id,
       1,
       'my.event',
       '{}'::jsonb::tag_map,
       0
FROM _ps_trace.span s;

SELECT is(count(*), 1::BIGINT, '_ps_trace.schema_url has 1 row') FROM _ps_trace.schema_url;
SELECT is(count(*), 1::BIGINT, '_ps_trace.instrumentation_lib has 1 row') FROM _ps_trace.instrumentation_lib;
SELECT is(count(*), 1::BIGINT, '_ps_trace.operation has 1 row') FROM _ps_trace.operation;
SELECT is(count(*), 1::BIGINT, '_ps_trace.tag_key has 1 row') FROM _ps_trace.tag_key WHERE id >= 1000;
SELECT is(count(*), 2::BIGINT, '_ps_trace.tag has 2 rows') FROM _ps_trace.tag;
SELECT is(count(*), 1::BIGINT, '_ps_trace.span has 1 row') FROM _ps_trace.span;
SELECT is(count(*), 1::BIGINT, '_ps_trace.link has 1 row') FROM _ps_trace.link;
SELECT is(count(*), 1::BIGINT, '_ps_trace.event has 1 row') FROM _ps_trace.event;

SELECT ps_trace.delete_all_traces();

SELECT is(count(*), 0::BIGINT, '_ps_trace.schema_url has 0 rows') FROM _ps_trace.schema_url;
SELECT is(count(*), 0::BIGINT, '_ps_trace.instrumentation_lib has 0 rows') FROM _ps_trace.instrumentation_lib;
SELECT is(count(*), 0::BIGINT, '_ps_trace.operation has 0 rows') FROM _ps_trace.operation;
SELECT is(count(*), 0::BIGINT, '_ps_trace.tag_key has 0 rows') FROM _ps_trace.tag_key WHERE id >= 1000;
SELECT is(count(*), 0::BIGINT, '_ps_trace.tag has 0 rows') FROM _ps_trace.tag;
SELECT is(count(*), 0::BIGINT, '_ps_trace.span has 0 rows') FROM _ps_trace.span;
SELECT is(count(*), 0::BIGINT, '_ps_trace.link has 0 rows') FROM _ps_trace.link;
SELECT is(count(*), 0::BIGINT, '_ps_trace.event has 0 rows') FROM _ps_trace.event;

SELECT * FROM finish(true);