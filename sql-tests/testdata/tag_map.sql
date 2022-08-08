\set ECHO all

-- We don't want retention to mess with the test data
SELECT ps_trace.set_trace_retention_period('100 years'::INTERVAL);

SELECT put_tag_key('char', ps_trace.span_tag_type());      /* 1001 */
SELECT put_tag_key('iteration', ps_trace.span_tag_type()); /* 1002 */
SELECT put_tag_key('pwlen', ps_trace.span_tag_type());     /* 1003 that is used */

INSERT INTO _ps_trace.tag(id,tag_type,key_id,key,value)
    OVERRIDING SYSTEM VALUE
    VALUES
    (93,2,6,'telemetry.sdk.language','"python"'),
    (94,2,5,'telemetry.sdk.name','"opentelemetry"'),
    (95,2,7,'telemetry.sdk.version','"1.8.0"'),
    (114,2,1,'service.name','"generator"'),
    (242,5,1003,'pwlen','18'),
    (247,5,1003,'pwlen','25');

INSERT INTO _ps_trace.span(trace_id,span_id,parent_span_id,operation_id,start_time,end_time,duration_ms,trace_state,span_tags,dropped_tags_count,event_time,dropped_events_count,dropped_link_count,status_code,status_message,instrumentation_lib_id,resource_tags,resource_dropped_tags_count,resource_schema_url_id)
    VALUES
        (E'78dd078e-8c69-e10a-d2fe-9e9f47de7728',-2771219554170079234,NULL,19,E'2022-04-26 11:44:55.185139+00',E'2022-04-26 11:44:55.38517+00',200.031,NULL,E'{"1003": 247}',0,E'["2022-04-26 11:44:55.185659+00","2022-04-26 11:44:55.385148+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'05a8be0f-bb79-c052-223e-48608580efce',2625299614982951051,NULL,19,E'2022-04-26 11:44:55.185962+00',E'2022-04-26 11:44:55.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL);

/* tag_map_denormalize function is actually called */
SELECT span_tags, resource_tags FROM ps_trace.span;

CREATE FUNCTION explain_jsonb(_query pg_catalog.text, OUT _result pg_catalog.jsonb)
    RETURNS pg_catalog.jsonb
    LANGUAGE plpgsql VOLATILE AS
$fnc$
BEGIN
    EXECUTE 'explain (format json, verbose, analyze) ' || _query INTO _result;
    RETURN;
END;
$fnc$;

/* Not equals operator returns correct result */
PREPARE neq_test AS
SELECT trace_id
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' != '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';

EXECUTE neq_test;

/* Not equals uses support function and produces correct plan */
SELECT
    x::text LIKE '%InitPlan%',
    x::text LIKE '% @> ANY%'
FROM explain_jsonb('EXECUTE neq_test') AS f(x);

/* Equals operator returns correct result */
PREPARE eq_test AS
SELECT trace_id
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' = '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';

/* Equals uses support function and produces correct plan */
SELECT
    x::text LIKE '%InitPlan%',
    x::text LIKE '% @> %'
FROM explain_jsonb('EXECUTE eq_test') AS f(x);

/* Functions, underpinning tag_map operators handle NULL arguments correctly */
SELECT ps_trace.tag_v_eq(NULL::_ps_trace.tag_v, NULL::pg_catalog.jsonb) IS NULL;
SELECT ps_trace.tag_v_eq(NULL::_ps_trace.tag_v, NULL::_ps_trace.tag_v) IS NULL;
SELECT ps_trace.tag_v_ne(NULL::_ps_trace.tag_v, NULL::pg_catalog.jsonb) IS NULL;
SELECT ps_trace.tag_v_ne(NULL::_ps_trace.tag_v, NULL::_ps_trace.tag_v) IS NULL;
SELECT ps_trace.tag_map_object_field(NULL, NULL) IS NULL;

/* Test tags in the link view */
INSERT INTO _ps_trace.link(trace_id, span_id, linked_trace_id, linked_span_id, tags, span_start_time)
    VALUES
        (E'78dd078e-8c69-e10a-d2fe-9e9f47de7728',-2771219554170079234, E'05a8be0f-bb79-c052-223e-48608580efce',2625299614982951051, E'{"1": 114, "5": 94, "6": 93, "7": 95}', E'2022-04-26 11:44:55.185139+00');

SELECT span_tags, resource_tags, linked_span_tags, linked_resource_tags, link_tags FROM link;

INSERT INTO _ps_trace.event(time, trace_id, span_id, name, tags)
    VALUES
        (E'2022-04-26 11:44:55.185139+00', E'78dd078e-8c69-e10a-d2fe-9e9f47de7728',-2771219554170079234, E'foobar', E'{"6": 93, "7": 95}');

SELECT event_tags, span_tags, resource_tags FROM event;

/* Distinct/group by for tag_v type */
SELECT DISTINCT span_tags -> 'pwlen' FROM span ;

SELECT span_tags -> 'pwlen' AS tagv FROM span  GROUP BY tagv;


\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(10);

SELECT is(_ps_trace.text_matches(input), expected, 'test text_matches')
FROM
(
    values
    ('regular text'   , array['"regular text"']::jsonb[]),
    ('true'           , array['"true"', 'true']::jsonb[]),
    ('false'          , array['"false"', 'false']::jsonb[]),
    ('1.0'          , array['"1.0"', '1.0']::jsonb[]),
    ('+2.0'          , array['"+2.0"', '2.0']::jsonb[]),
    ('10'          , array['"10"', '10']::jsonb[]),
    ('-20'          , array['"-20"', '-20']::jsonb[])
) x(input, expected)
;

set enable_seqscan=off;

SELECT
  ok(j @? '$.**."Subplan Name" ? (@ == "InitPlan 1 (returns $0)")','subplan is used'),
  ok(j @? '$.**."Index Cond" ?  (@ like_regex ".*span_tags.*::jsonb @> ANY .*\\\$0.*")', 'uses index')
FROM
explain_jsonb(
    $$
        SELECT *
        FROM _ps_trace.span
        WHERE span_tags @> ANY((SELECT _ps_trace.tag_v_text_eq_matching_tags('pwlen', '25'))::jsonb[])
    $$) j;

--the following case should get optimized with https://github.com/timescale/timescaledb/pull/4556, because the matching tags will be an empty array
--this will need to be changed after that's merged
SELECT
    ok(j @? '$.** ? (@."Custom Plan Provider" == "ChunkAppend" && @."Runtime Exclusion" == false)', 'exclusion does not happen')
FROM
explain_jsonb(
    $$
       SELECT * FROM _ps_trace.span WHERE span_tags @> ANY((SELECT _ps_trace.tag_v_text_eq_matching_tags('pwlen', 'does not exist'))::jsonb[]);
    $$) j;

RESET enable_seqscan;

SELECT * FROM finish(true);