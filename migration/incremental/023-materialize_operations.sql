--need this index on span to search by start_time
CREATE INDEX span_start_time ON _ps_trace.span(start_time);

CREATE TABLE _ps_trace.operation_materialization (
    parent_start_time timestamptz,
    parent_operation_id bigint,
    child_operation_id bigint,
    cnt bigint,
    --todo what else,
    UNIQUE(parent_start_time, parent_operation_id, child_operation_id)
);

PERFORM public.create_hypertable(
            '_ps_trace.operation_materialization'::regclass,
            'parent_start_time'::name,
            chunk_time_interval=>'168 hours'::interval, --7 days
            create_default_indexes=>false);


--stub job function. will be redefined later
CREATE OR REPLACE PROCEDURE _ps_trace.execute_materialize_operations_job(job_id int, config jsonb)
AS $$
BEGIN
END
$$ LANGUAGE PLPGSQL;

--keep this separate from the other jobs for independence and also since the right
--schedule here is always "ever 10 min". We never want this to run in parallel so
--it's always just one job making progress. This job is usally pretty quiet so enable
--logging by default (should chirp once every 10 min).
PERFORM public.add_job('_ps_trace.execute_materialize_operations_job', INTERVAL '10 minutes', config=>JSONB '{"log_verbose":true}');