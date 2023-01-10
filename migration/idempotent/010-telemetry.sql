-- promscale_telemetry_housekeeping() does telemetry housekeeping stuff, which includes
-- searching the table for telemetry_sync_duration, looking for stale promscales, if found,
-- adding their values into the counter_reset row, and then cleaning up the stale
-- promscale instances.
-- It is concurrency safe, since it takes lock on the promscale_instance_information table,
-- making sure that at one time, only one housekeeping is being done.
-- 
-- It returns TRUE if last run was beyond telemetry_sync_duration, otherwise FALSE.
CREATE OR REPLACE FUNCTION _ps_catalog.promscale_telemetry_housekeeping(telemetry_sync_duration INTERVAL DEFAULT INTERVAL '1 HOUR')
RETURNS BOOLEAN
SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE
        should_update_telemetry BOOLEAN;
    BEGIN
        BEGIN
            LOCK TABLE _ps_catalog.promscale_instance_information IN ACCESS EXCLUSIVE MODE NOWAIT; -- Do not wait for the lock as some promscale is already cleaning up the stuff.
        EXCEPTION
            WHEN SQLSTATE '55P03' THEN
                RETURN FALSE;
        END;

        -- This guarantees that we update our telemetry once every telemetry_sync_duration.
        SELECT count(*) = 0 INTO should_update_telemetry FROM _ps_catalog.promscale_instance_information
            WHERE is_counter_reset_row = TRUE AND current_timestamp - last_updated < telemetry_sync_duration;

        IF NOT should_update_telemetry THEN
            -- Some Promscale did the housekeeping work within the expected interval. Hence, nothing to do, so exit.
            RETURN FALSE;
        END IF;


        WITH deleted_rows AS (
            DELETE FROM _ps_catalog.promscale_instance_information
            WHERE is_counter_reset_row = FALSE AND current_timestamp - last_updated > (telemetry_sync_duration * 2) -- consider adding stats of deleted rows to persist counter reset behaviour.
            RETURNING *
        )
        UPDATE _ps_catalog.promscale_instance_information SET
            promscale_ingested_samples_total                    = promscale_ingested_samples_total + COALESCE(x.del_promscale_ingested_samples_total, 0),
            promscale_ingested_spans_total                      = promscale_ingested_spans_total + COALESCE(x.del_promscale_ingested_spans_total, 0),
            promscale_metrics_queries_success_total             = promscale_metrics_queries_success_total + COALESCE(x.del_promscale_metrics_queries_success_total, 0),
            promscale_metrics_queries_timedout_total            = promscale_metrics_queries_timedout_total + COALESCE(x.del_promscale_metrics_queries_timedout_total, 0),
            promscale_metrics_queries_failed_total              = promscale_metrics_queries_failed_total + COALESCE(x.del_promscale_metrics_queries_failed_total, 0),
            promscale_trace_query_requests_executed_total       = promscale_trace_query_requests_executed_total + COALESCE(x.del_promscale_trace_query_requests_executed_total, 0),
            promscale_trace_dependency_requests_executed_total  = promscale_trace_dependency_requests_executed_total + COALESCE(x.del_promscale_trace_dependency_requests_executed_total, 0),
            last_updated = current_timestamp
        FROM
        (
            SELECT
                sum(promscale_ingested_samples_total)  			        as del_promscale_ingested_samples_total,
                sum(promscale_ingested_spans_total)  			        as del_promscale_ingested_spans_total,
                sum(promscale_metrics_queries_success_total)  		    as del_promscale_metrics_queries_success_total,
                sum(promscale_metrics_queries_timedout_total)  		    as del_promscale_metrics_queries_timedout_total,
                sum(promscale_metrics_queries_failed_total)  		    as del_promscale_metrics_queries_failed_total,
                sum(promscale_trace_query_requests_executed_total)      as del_promscale_trace_query_requests_executed_total,
                sum(promscale_trace_dependency_requests_executed_total) as del_promscale_trace_dependency_requests_executed_total
            FROM
                deleted_rows
        ) x
        WHERE is_counter_reset_row = TRUE;

        RETURN TRUE;
    END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _ps_catalog.promscale_telemetry_housekeeping(INTERVAL) TO prom_writer;

CREATE OR REPLACE FUNCTION _ps_catalog.promscale_sql_telemetry() RETURNS VOID
SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE result TEXT;
    BEGIN
        -- Metrics telemetry.
        SELECT count(*)::TEXT INTO result FROM _prom_catalog.metric;
        PERFORM _ps_catalog.apply_telemetry('metrics_total', result);

        SELECT public.approximate_row_count('_prom_catalog.series')::TEXT INTO result;
        PERFORM _ps_catalog.apply_telemetry('metrics_series_total_approx', result);

        SELECT count(*)::TEXT INTO result FROM _prom_catalog.label WHERE key = '__tenant__';
        PERFORM _ps_catalog.apply_telemetry('metrics_multi_tenancy_tenant_count', result);

        SELECT count(*)::TEXT INTO result FROM _prom_catalog.label WHERE key = 'cluster';
        PERFORM _ps_catalog.apply_telemetry('metrics_ha_cluster_count', result);

        SELECT count(*)::TEXT INTO result FROM _prom_catalog.metric WHERE is_view IS true;
        PERFORM _ps_catalog.apply_telemetry('metrics_registered_views', result);

        SELECT count(*)::TEXT INTO result FROM _prom_catalog.exemplar;
        PERFORM _ps_catalog.apply_telemetry('metrics_exemplar_total', result);

        SELECT count(*)::TEXT INTO result FROM _prom_catalog.metadata;
        PERFORM _ps_catalog.apply_telemetry('metrics_metadata_total', result);

        SELECT _prom_catalog.get_default_value('retention_period') INTO result;
        PERFORM _ps_catalog.apply_telemetry('metrics_default_retention', result);

        SELECT _prom_catalog.get_default_value('chunk_interval') INTO result;
        PERFORM _ps_catalog.apply_telemetry('metrics_default_chunk_interval', result);

        -- Metric downsampling.
        SELECT prom_api.get_automatic_downsample()::TEXT INTO result;
        PERFORM _ps_catalog.apply_telemetry('metrics_downsampling_enabled', result);

        SELECT array_agg(ds_interval || ':' || retention)::TEXT INTO result FROM _prom_catalog.downsample; -- Example: {00:05:00:720:00:00,01:00:00:8760:00:00} => {HH:MM:SS}
        PERFORM _ps_catalog.apply_telemetry('metrics_downsampling_configs', result);

        IF ( SELECT count(*)>0 FROM _prom_catalog.metric WHERE metric_name = 'prometheus_tsdb_head_series' ) THEN
            -- Calculate active series in Promscale. This is done by taking the help of the Prometheus metric 'prometheus_tsdb_head_series'.
            -- An active series for Promscale is basically sum of active series of all Prometheus instances writing into Promscale
            -- within the last 30 minutes at least.
            SELECT sum(active_series)::TEXT INTO result FROM
            (
                SELECT
                    series_id, public.last(value, time) AS active_series
                FROM prom_data.prometheus_tsdb_head_series
                    WHERE time > now() - INTERVAL '30 minutes' GROUP BY series_id
            ) a;
            PERFORM _ps_catalog.apply_telemetry('metrics_active_series', result);
        END IF;

        -- Traces telemetry.
        SELECT (CASE
                    WHEN n_distinct >= 0 THEN
                        --positive values represent an absolute number of distinct elements
                        n_distinct
                    ELSE
                        --negative values represent number of distinct elements as a proportion of the total
                        -n_distinct * public.approximate_row_count('_ps_trace.span')
                END)::TEXT INTO result
        FROM pg_stats
        WHERE schemaname='_ps_trace' AND tablename='span' AND attname='trace_id' AND inherited;
        PERFORM _ps_catalog.apply_telemetry('traces_total_approx', result);

        SELECT public.approximate_row_count('_ps_trace.span')::TEXT INTO result;
        PERFORM _ps_catalog.apply_telemetry('traces_spans_total_approx', result);

        -- According to [1], Trace spans processed by Jaeger collector will have an internal attribute named 'internal.span.format' with one of the values 'jaeger|zipkin|proto|otlp|unknown'[2]. We can use this to infer whether promscale's gRPC remote storage implementation has been used or not.
        -- [1] https://github.com/jaegertracing/jaeger/issues/1490
        -- [2] https://github.com/jaegertracing/jaeger/blob/b7088238c017e5a54896efbf5ed38959e885e0c5/cmd/collector/app/processor/interface.go#L56-L67
        SELECT ARRAY_AGG(value)::TEXT INTO result FROM _ps_trace.tag WHERE key='internal.span.format' AND _prom_ext.jsonb_digest(value) IN (_prom_ext.jsonb_digest('"jaeger"'), _prom_ext.jsonb_digest('"zipkin"'), _prom_ext.jsonb_digest('"proto"'), _prom_ext.jsonb_digest('"otlp"'), _prom_ext.jsonb_digest('"unknown"'));
        PERFORM _ps_catalog.apply_telemetry('traces_jaeger_span_types', result);

        -- Others.
        -- The -1 is to ignore the row summing deleted rows i.e., the counter reset row. 
        SELECT (count(*) - 1)::TEXT INTO result FROM _ps_catalog.promscale_instance_information;
        PERFORM _ps_catalog.apply_telemetry('connector_instance_total', result);

        SELECT count(*)::TEXT INTO result FROM timescaledb_information.data_nodes;
        PERFORM _ps_catalog.apply_telemetry('db_node_count', result);

        SELECT current_timestamp::TEXT INTO result; -- UTC timestamp.
        PERFORM _ps_catalog.apply_telemetry('telemetry_last_updated', result);
    END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _ps_catalog.promscale_sql_telemetry() TO prom_writer;

--security definer function that allows setting metadata with the promscale_prefix
CREATE OR REPLACE FUNCTION _prom_ext.update_tsprom_metadata(meta_key text, meta_value text, send_telemetry BOOLEAN)
    RETURNS VOID
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    INSERT INTO _timescaledb_catalog.metadata(key, value, include_in_telemetry)
    VALUES ('promscale_' || meta_key,meta_value, send_telemetry)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, include_in_telemetry = EXCLUDED.include_in_telemetry
$func$
LANGUAGE SQL;
REVOKE ALL ON FUNCTION _prom_ext.update_tsprom_metadata(TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_ext.update_tsprom_metadata(TEXT, TEXT, BOOLEAN) TO prom_writer;

CREATE OR REPLACE FUNCTION _ps_catalog.apply_telemetry(telemetry_name TEXT, telemetry_value TEXT)
RETURNS VOID
SET search_path = pg_catalog, pg_temp
AS
$$
    BEGIN
        IF telemetry_value IS NULL THEN
            telemetry_value := '0';
        END IF;

        -- First try to use promscale_extension to fill the metadata table.
        PERFORM _prom_ext.update_tsprom_metadata(telemetry_name, telemetry_value, TRUE);

        -- If promscale_extension is not installed, the above line will fail. Hence, catch the exception and try the manual way.
        EXCEPTION WHEN OTHERS THEN
            -- If this fails, throw an error so that the connector can log (or not) as appropriate.
            INSERT INTO _timescaledb_catalog.metadata(key, value, include_in_telemetry) VALUES ('promscale_' || telemetry_name, telemetry_value, TRUE) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, include_in_telemetry = EXCLUDED.include_in_telemetry;
    END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _ps_catalog.apply_telemetry(TEXT, TEXT) TO prom_writer;
