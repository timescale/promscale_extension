\set ECHO all
\set ON_ERROR_STOP 1

CREATE EXTENSION promscale;

CREATE OR REPLACE VIEW real_view AS  --non-materialized view. i.e. source of truth
SELECT
    public.time_bucket('10 minute', parent.start_time) parent_start_time,
    parent.operation_id as parent_operation_id,
    child.operation_id as child_operation_id,
    count(*) as cnt
FROM
    _ps_trace.span parent
INNER JOIN
    _ps_trace.span child ON (parent.span_id = child.parent_span_id AND parent.trace_id = child.trace_id)
GROUP BY
    parent_start_time,
    parent.operation_id,
    child.operation_id;

INSERT INTO _ps_trace.span(trace_id,span_id,parent_span_id,operation_id,start_time,end_time,duration_ms,trace_state,span_tags,dropped_tags_count,event_time,dropped_events_count,dropped_link_count,status_code,status_message,instrumentation_lib_id,resource_tags,resource_dropped_tags_count,resource_schema_url_id)
    VALUES
        --trace 1
        (E'15a8be0f-bb79-c052-223e-48608580efce',1,NULL,1,E'2022-04-26 11:44:55.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'15a8be0f-bb79-c052-223e-48608580efce',2,1,2,E'2022-04-26 11:44:55.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'15a8be0f-bb79-c052-223e-48608580efce',3,2,3,E'2022-04-26 11:44:56.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
       --trace 2
        (E'25a8be0f-bb79-c052-223e-48608580efce',1,NULL,1,E'2022-04-26 11:44:55.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'25a8be0f-bb79-c052-223e-48608580efce',2,1,2,E'2022-04-26 11:44:55.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'25a8be0f-bb79-c052-223e-48608580efce',3,2,3,E'2022-04-26 11:44:56.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
        (E'25a8be0f-bb79-c052-223e-48608580efce',4,2,3,E'2022-04-26 11:44:57.185962+00',E'2022-04-26 11:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL);

--correctness check
SELECT * FROM real_view
EXCEPT
SELECT * FROM _ps_trace.operation_stats;

SET client_min_messages = 'LOG';

SELECT _ps_trace.materialize_watermark();
CALL _ps_trace.execute_materialize_operations_job(0, jsonb '{"log_verbose": true,"log_timing":false}'); --should not do anything since there are no traces that are older than 20 min from the last one
SELECT _ps_trace.materialize_watermark();

INSERT INTO _ps_trace.span(trace_id,span_id,parent_span_id,operation_id,start_time,end_time,duration_ms,trace_state,span_tags,dropped_tags_count,event_time,dropped_events_count,dropped_link_count,status_code,status_message,instrumentation_lib_id,resource_tags,resource_dropped_tags_count,resource_schema_url_id)
    VALUES
--trace 3, an hour later
(E'35a8be0f-bb79-c052-223e-48608580efce',1,NULL,1,E'2022-04-26 12:44:55.185962+00',E'2022-04-26 12:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
(E'35a8be0f-bb79-c052-223e-48608580efce',2,1,2,E'2022-04-26 12:44:55.185962+00',E'2022-04-26 12:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
(E'35a8be0f-bb79-c052-223e-48608580efce',3,2,3,E'2022-04-26 12:44:56.185962+00',E'2022-04-26 12:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
(E'35a8be0f-bb79-c052-223e-48608580efce',4,2,4,E'2022-04-26 12:44:57.185962+00',E'2022-04-26 12:44:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL);

SELECT _ps_trace.materialize_watermark();
CALL _ps_trace.execute_materialize_operations_job(0, jsonb '{"log_verbose": true,"log_timing":false}'); --materialize the first two traces
SELECT _ps_trace.materialize_watermark(); --note will be the last bucket that actually had data

CALL _ps_trace.execute_materialize_operations_job(0, jsonb '{"log_verbose": true,"log_timing":false}'); -- will rematerialize the buckets that were previously empty (do we want this property?)
SELECT _ps_trace.materialize_watermark(); --but they are still empty

--correctness check
SELECT * FROM real_view
EXCEPT
SELECT * FROM _ps_trace.operation_stats;

INSERT INTO _ps_trace.span(trace_id,span_id,parent_span_id,operation_id,start_time,end_time,duration_ms,trace_state,span_tags,dropped_tags_count,event_time,dropped_events_count,dropped_link_count,status_code,status_message,instrumentation_lib_id,resource_tags,resource_dropped_tags_count,resource_schema_url_id)
    VALUES
--trace 4, 20 min later later
(E'45a8be0f-bb79-c052-223e-48608580efce',1,NULL,1,E'2022-04-26 13:04:55.185962+00',E'2022-04-26 13:04:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
(E'45a8be0f-bb79-c052-223e-48608580efce',2,1,2,E'2022-04-26 13:04:55.185962+00',E'2022-04-26 13:04:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
(E'45a8be0f-bb79-c052-223e-48608580efce',3,2,3,E'2022-04-26 13:04:56.185962+00',E'2022-04-26 13:04:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL),
(E'45a8be0f-bb79-c052-223e-48608580efce',4,2,4,E'2022-04-26 13:04:57.185962+00',E'2022-04-26 13:04:60.288812+00',102.85,NULL,E'{"1003": 242}',0,E'["2022-04-26 11:44:55.185999+00","2022-04-26 11:44:55.288781+00")',0,0,E'error',E'Exception: FAILED to fetch a lower char',5,E'{"1": 114, "5": 94, "6": 93, "7": 95}',0,NULL);

CALL _ps_trace.execute_materialize_operations_job(0, jsonb '{"log_verbose": true,"log_timing":false}'); --materialize the third trace traces
SELECT _ps_trace.materialize_watermark();

CALL _ps_trace.execute_materialize_operations_job(0, jsonb '{"log_verbose": true,"log_timing":false}'); -- noop
SELECT _ps_trace.materialize_watermark();

--correctness check
SELECT * FROM real_view
EXCEPT
SELECT * FROM _ps_trace.operation_stats;