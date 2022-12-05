CREATE OR REPLACE PROCEDURE _prom_catalog.execute_caggs_refresh_policy(job_id int, config jsonb)
AS
$$
DECLARE
    _refresh_interval INTERVAL;
    _refresh_rollups BOOLEAN := (SELECT prom_api.get_automatic_downsample()::BOOLEAN);
    _active_chunk_interval INTERVAL := (SELECT _prom_catalog.get_default_chunk_interval()::INTERVAL * 2);
    _ignore_rollups_clause TEXT := '';
    r RECORD;

BEGIN
    SET LOCAL search_path = pg_catalog, pg_temp;

    _refresh_interval := (config ->> 'refresh_interval')::INTERVAL;
    IF _refresh_interval IS NULL THEN
        RAISE EXCEPTION 'refresh_interval cannot be null';
    END IF;

    IF NOT _refresh_rollups THEN
        _ignore_rollups_clause := 'AND m.rollup_id IS NULL';
    END IF;

    FOR r IN
        -- We need to refresh the custom caggs at the minimum.
        -- The choice of not refreshing is applicable only on metric-rollups, depending on the value of _refresh_rollups.
        EXECUTE FORMAT('
            SELECT
                m.table_schema,
                m.table_name
            FROM _prom_catalog.metric m
            WHERE m.is_view %s AND m.view_refresh_interval = $1::INTERVAL
       ', _ignore_rollups_clause) USING _refresh_interval
    LOOP
        -- Refresh on inactive chunks so we do not disturb ingestion.
        CALL public.refresh_continuous_aggregate(format('%I.%I', r.table_schema, r.table_name), current_timestamp - _active_chunk_interval - 4 * _refresh_interval, current_timestamp - _active_chunk_interval - 2 * _refresh_interval);
        COMMIT; -- Commit after every refresh to avoid high I/O & mem-buffering.
        SET LOCAL search_path = pg_catalog, pg_temp;
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.execute_caggs_refresh_policy IS 'execute_caggs_refresh_policy runs every refresh_interval passed in config. Its
main aim is to refresh those Caggs that have been registered under _prom_catalog.metric and whose view_refresh_interval
matches the given refresh_interval. It refreshes 2 kinds of Caggs:
1. Caggs created by metric rollups
2. Custom Caggs created by the user';

CREATE OR REPLACE FUNCTION _prom_catalog.create_cagg_refresh_job_if_not_exists(_refresh_interval INTERVAL) RETURNS VOID
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    IF (
        SELECT EXISTS (
            SELECT 1 FROM timescaledb_information.jobs WHERE
               proc_name = 'execute_caggs_refresh_policy' AND schedule_interval = _refresh_interval
        )
    ) THEN
        -- Refresh job exists for the given _refresh_interval. Hence, nothing to do.
        RETURN;
    END IF;
    PERFORM public.add_job('_prom_catalog.execute_caggs_refresh_policy', _refresh_interval, json_build_object('refresh_interval', _refresh_interval)::jsonb);
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION _prom_catalog.create_cagg_refresh_job_if_not_exists(INTERVAL) IS
'Creates a Cagg refresh job that refreshes all Caggs registered by register_metric_view().
This function creates a refresh job only if no execute_caggs_refresh_policy() exists currently with the given refresh_interval.';

CREATE OR REPLACE PROCEDURE _prom_catalog.execute_caggs_compression_policy(job_id int, config jsonb)
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    r RECORD;

BEGIN
    FOR r IN
        SELECT
            format('%I.%I', m.table_schema, m.table_name) AS compressible_cagg,
            m.view_refresh_interval AS refresh_interval
        FROM
            _prom_catalog.metric m
        INNER JOIN
            timescaledb_information.continuous_aggregates cagg
        ON (m.table_name = cagg.view_name AND m.table_schema = cagg.view_schema)
        WHERE
            cagg.compression_enabled AND m.is_view
    LOOP
        PERFORM public.compress_chunk(public.show_chunks(r.compressible_cagg, older_than => 100 * r.refresh_interval), true);
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.execute_caggs_compression_policy IS 'execute_caggs_compression_policy is responsible to compress Caggs registered via
register_metric_view() in _prom_catalog.metric. It goes through all the entries in the _prom_catalog.metric and tries to compress any Cagg that supports compression.
These include metric-rollups and custom Caggs based downsampling.
Note: execute_caggs_compression_policy runs every X interval and compresses only the inactive chunks of those Caggs which have timescaledb.compress = true.
By default, these include metric-rollups.';

CREATE OR REPLACE PROCEDURE _prom_catalog.execute_caggs_retention_policy(job_id int, config jsonb)
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    r RECORD;
    _retention INTERVAL;

BEGIN
    -- For retention, we have 2 cases:
    -- Case 1: Retention for metric-rollups
    -- These Caggs have a defined retention duration that is stored in the _prom_catalog.rollup
    --
    -- Case 2: Retention for custom Caggs
    -- These Caggs do not have a well definied policy for retention. Hence, we will assume the
    -- retention to be the metric_retention_period(cagg_name), which itself is either the global
    -- retention or retention specific to that cagg view stored in 'retention_period' column of
    -- _prom_catalog.metric

    -- Case 1.
    FOR r IN
        SELECT
            format('%I.%I', rp.schema_name, m.table_name) AS cagg,
            rp.retention as rollup_retention
        FROM _prom_catalog.metric m
        INNER JOIN _prom_catalog.metric_rollup mr ON (m.id = mr.metric_id)
        INNER JOIN _prom_catalog.rollup rp ON (mr.rollup_id = rp.id)
    LOOP
        PERFORM public.drop_chunks(r.cagg, older_than => r.rollup_retention);
    END LOOP;

    -- Case 2.
    FOR r IN
        SELECT
            format('%I.%I', table_schema, metric_name) AS cagg,
            metric_name AS cagg_name -- Note: This is the name of cagg view.
        FROM _prom_catalog.metric WHERE is_view AND rollup_id IS NULL
    LOOP
        _retention := (SELECT _prom_catalog.get_metric_retention_period(r.cagg_name));
        PERFORM public.drop_chunks(r.cagg, older_than => _retention);
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.execute_caggs_retention_policy IS 'execute_caggs_retention_policy is responsible to perform retention behaviour on compress continuous aggregates registered via
register_metric_view(). It loops through all entries in the _prom_catalog.metric that are Caggs and tries to delete the stale chunks of those Caggs.
The staleness is determined by rollup_retention (for metric rollups) and default_retention_period of parent hypertable (for custom Caggs).
These include metric-rollups and custom Caggs based downsampling.';

DO $$
DECLARE
    _is_restore_in_progress boolean = false;
    _job_already_exists boolean := false;

BEGIN
    _is_restore_in_progress = coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND NOT _is_restore_in_progress
    THEN
        -- Add a execute_caggs_compression_policy job if not exist.
        _job_already_exists := (SELECT EXISTS(SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_compression_policy')::boolean);
        IF NOT _job_already_exists THEN
            PERFORM public.add_job('_prom_catalog.execute_caggs_compression_policy', INTERVAL '30 minutes');
        END IF;

        -- Add a execute_caggs_retention_policy job if not exist.
        _job_already_exists := (SELECT EXISTS(SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'execute_caggs_retention_policy')::boolean);
        IF NOT _job_already_exists THEN
            PERFORM public.add_job('_prom_catalog.execute_caggs_retention_policy', INTERVAL '30 minutes');
        END IF;
    END IF;
END;
$$;
