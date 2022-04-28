\set ECHO all
\set ON_ERROR_STOP 1

CREATE EXTENSION promscale;

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
        (E'78dd078e-8c69-e10a-d2fe-9e9f47de7728',-2771219554170079234,NULL,19,E'2022-04-26 11:44:55.185139+00',E'2022-04-26 11:44:55.38517+00',200.031,NULL,E'{"1003": 247}',0,E'["2022-04-26 11:44:55.185659+00","2022-04-26 11:44:55.385148+00")',0,0,E'STATUS_CODE_ERROR',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'05a8be0f-bb79-c052-223e-48608580efce',2625299614982951051,NULL,19,E'2022-04-26 11:44:55.185962+00',E'2022-04-26 11:44:55.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'STATUS_CODE_ERROR',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL);
/* tag_map_denormalize function is actually called */
SELECT span_tags, resource_tags FROM ps_trace.span;

/* Not equals operator returns correct result */
SELECT trace_id
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' != '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';

/* Not equals uses support function and produces correct plan */
EXPLAIN (costs off) SELECT *
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' != '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';

/* Equals operator returns correct result */
SELECT trace_id
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' = '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';

/* Equals uses support function and produces correct plan */
EXPLAIN (costs off) SELECT *
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' = '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';
