-- returns the time stamp before which the materialization is valid (exclusive)
-- it is important for this to be effecient: the span_start_time index guarantees
-- effeciency in this case.
CREATE OR REPLACE FUNCTION _ps_trace.materialize_watermark()
RETURNS timestamptz
STABLE
AS
$func$
    SELECT parent_start_time + interval '10 minutes' --time_bucket returns the lower end of the bucket so add an interval
    FROM _ps_trace.operation_materialization
    ORDER BY parent_start_time DESC
    LIMIT 1
$func$
LANGUAGE SQL;

--This procedure updates the materialization
CREATE OR REPLACE PROCEDURE _ps_trace.execute_materialize_operations(log_verbose boolean = false, log_timing boolean = true)
AS $func$
DECLARE
   _start TIMESTAMPTZ;
   _global_end TIMESTAMPTZ;
   _query_start timestamptz;
   _bucket INTERVAL = INTERVAL '10 minute';
BEGIN
    --one materialization run at a time (we don't want parallel execution),
    --so lock in a self-exclusive way.
    --This lock also protects against concurrent data modifications which
    --may not be strictly necessary. If this becomes an issue consider
    --using SHARE UPDATE EXCLUSIVE instead.
    LOCK TABLE ONLY _ps_trace.operation_materialization IN SHARE ROW EXCLUSIVE MODE;

    _start := _ps_trace.materialize_watermark();

    IF _start IS NULL THEN
        --no materialization exists, get the first existing bucket in the underlyong data
        SELECT public.time_bucket(_bucket, start_time) INTO _start
        FROM _ps_trace.span
        ORDER BY start_time ASC
        LIMIT 1;
    END IF;

    --we want to materialize up to 1 bucket before the not yet filled bucket
    --this reduces the chance of data getting backfilled and the materialization
    --having invalid results. So, if I am seeing data at 02:23 I want to materialize
    --up until 02:10. An alternative here is to always re-materialize the head
    --bucket twice. Consider this if the "real-time" part of the query gets too
    --expensive.
    SELECT public.time_bucket(_bucket, start_time) - _bucket INTO _global_end
    FROM _ps_trace.span
    ORDER BY start_time DESC
    LIMIT 1;

    --we materialize one bucket at a time until we are done. We do this so that
    --we can make steady progress even if we are pretty far behind.
    WHILE (_start + _bucket) <= _global_end LOOP
        PERFORM _prom_catalog.set_app_name(pg_catalog.format('promscale maintenance: materializing operations: start %L', _start));
        _query_start := clock_timestamp ();
        INSERT INTO _ps_trace.operation_materialization
        SELECT
            public.time_bucket(_bucket, parent.start_time) bucket,
            parent.operation_id as parent_operation_id,
            child.operation_id as child_operation_id,
            count(*) as cnt
        FROM
            _ps_trace.span parent
        INNER JOIN
            _ps_trace.span child ON (parent.span_id = child.parent_span_id AND parent.trace_id = child.trace_id)
        WHERE
            parent.start_time >= _start AND parent.start_time < (_start + _bucket)
            -- 2 assumptions
            -- a) that a child span starts after the parent span starts
            -- b) a child span starts no later than an hour after the parent starts
            AND child.start_time >= _start AND child.start_time < (_start + _bucket + pg_catalog.interval '1 hour')
        GROUP BY
            bucket,
            parent.operation_id,
            child.operation_id;

        IF log_verbose THEN
            IF log_timing THEN
                RAISE LOG 'materializing operations: from % to %, took: %', _start, _start + _bucket, clock_timestamp() - _query_start;
            ELSE
                RAISE LOG 'materializing operations: from % to %', _start, _start + _bucket;
            END IF;
        END IF;

        --save our work!
        COMMIT;
        _start = _start + _bucket;
    END LOOP;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _ps_trace.execute_materialize_operations(boolean, boolean) TO prom_maintenance;


--This is the view that we can query. It's a "real time" view (like in continous aggregates)
--which means it combines the materialized portion with a fresh rollup of the data from the
--underlying table for the data that has not-yet-been-materialized. This means it should be
--the same as a fresh rollup in all cases except invalidation (e.g. changes to data that
--has already been materialized, which we don't handle yet).
CREATE OR REPLACE VIEW _ps_trace.operation_stats AS --TODO: should this be public?
SELECT
    parent_start_time as parent_start_time,
    parent_operation_id as parent_operation_id,
    child_operation_id as child_operation_id,
    cnt bigint
FROM  _ps_trace.operation_materialization
WHERE parent_start_time < COALESCE(_ps_trace.materialize_watermark(), '-infinity'::timestamp with time zone)
UNION ALL
SELECT
    public.time_bucket('10 minute', parent.start_time) parent_start_time,
    parent.operation_id as parent_operation_id,
    child.operation_id as child_operation_id,
    count(*) as cnt
FROM
    _ps_trace.span parent
INNER JOIN
    _ps_trace.span child ON (parent.span_id = child.parent_span_id AND parent.trace_id = child.trace_id)
WHERE
    parent.start_time >= COALESCE(_ps_trace.materialize_watermark(), '-infinity'::timestamp with time zone)
    --assumes the child span starts on or after the parent starts
    AND child.start_time >= COALESCE(_ps_trace.materialize_watermark(), '-infinity'::timestamp with time zone)
GROUP BY
    parent_start_time,
    parent.operation_id,
    child.operation_id;


--job infrastructure function boilerplate
CREATE OR REPLACE PROCEDURE _ps_trace.execute_materialize_operations_job(job_id int, config jsonb)
AS $$
DECLARE
   log_verbose boolean;
   log_timing boolean;
   ae_key text;
   ae_value text;
   ae_load boolean := FALSE;
BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;
    log_verbose := coalesce(config->>'log_verbose', 'false')::boolean;
    log_timing := coalesce(config->>'log_timing', 'true')::boolean;

    --if auto_explain enabled in config, turn it on in a best-effort way
    --i.e. if it fails (most likely due to lack of superuser priviliges) move on anyway.
    BEGIN
        FOR ae_key, ae_value IN
           SELECT * FROM jsonb_each_text(config->'auto_explain')
        LOOP
            IF NOT ae_load THEN
                ae_load := true;
                LOAD 'auto_explain';
            END IF;

            PERFORM set_config('auto_explain.'|| ae_key, ae_value, FALSE);
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'could not set auto_explain options';
    END;


    CALL _ps_trace.execute_materialize_operations(log_verbose=>log_verbose, log_timing=>log_timing);
END
$$ LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _ps_trace.execute_materialize_operations_job(int, jsonb) TO prom_maintenance;