
-- Fix compression on trace tables
DO $block$
DECLARE
    _is_timescaledb_installed boolean = false;
    _is_compression_available boolean = false;
    _saved_search_path text;
BEGIN
    _is_timescaledb_installed = _prom_catalog.is_timescaledb_installed();

    IF _is_timescaledb_installed THEN
        _is_compression_available = NOT (current_setting('timescaledb.license') = 'apache');
    END IF;

    IF _is_timescaledb_installed THEN
        --need to clear the search path while creating distributed
        --hypertables because otherwise the datanodes don't find
        --the right column types since type names are not schema
        --qualified if in search path.
        _saved_search_path := current_setting('search_path');
        SET search_path = pg_temp;

        PERFORM public.set_chunk_time_interval(
            '_ps_trace.span'::regclass,
            '1 hour'::interval
        );
        PERFORM public.set_chunk_time_interval(
            '_ps_trace.event'::regclass,
            '1 hour'::interval
        );
        PERFORM public.set_chunk_time_interval(
            '_ps_trace.link'::regclass,
            '1 hour'::interval
        );

        execute format('SET search_path = %s', _saved_search_path);

        IF _is_compression_available THEN
            -- drop any compressed chunks for the three tables we are modifying
            PERFORM public.drop_chunks(
                format('%I.%I', hypertable_schema, hypertable_schema)::regclass,
                (max(range_end) + interval '1 minute'),
                verbose=>true
            )
            FROM timescaledb_information.chunks
            WHERE is_compressed = true
            AND (hypertable_schema, hypertable_name) IN
            (
                ('_ps_trace', 'span'),
                ('_ps_trace', 'link'),
                ('_ps_trace', 'event')
            )
            GROUP BY hypertable_schema, hypertable_name
            ORDER BY hypertable_name DESC -- span table last
            ;

            PERFORM public.remove_compression_policy('_ps_trace.span', if_exists=>true);
            PERFORM public.remove_compression_policy('_ps_trace.event', if_exists=>true);
            PERFORM public.remove_compression_policy('_ps_trace.link', if_exists=>true);

            ALTER TABLE _ps_trace.span SET (timescaledb.compress=false);
            ALTER TABLE _ps_trace.event SET (timescaledb.compress=false);
            ALTER TABLE _ps_trace.link SET (timescaledb.compress=false);

            ALTER TABLE _ps_trace.span SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,start_time');
            ALTER TABLE _ps_trace.event SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,time');
            ALTER TABLE _ps_trace.link SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,span_start_time');

            PERFORM public.add_compression_policy('_ps_trace.span', INTERVAL '1 hours');
            PERFORM public.add_compression_policy('_ps_trace.event', INTERVAL '1 hours');
            PERFORM public.add_compression_policy('_ps_trace.link', INTERVAL '1 hours');
        END IF;
    END IF;
END;
$block$
;
