CREATE OR REPLACE PROCEDURE _prom_catalog.caggs_refresher(job_id int, config jsonb) AS
$$
DECLARE
    _refresh_interval INTERVAL := config ->> 'refresh_interval';
    r RECORD;

BEGIN
    FOR r IN
        SELECT table_schema, table_name FROM _prom_catalog.metric
           WHERE is_view IS TRUE AND view_refresh_interval = _refresh_interval
    LOOP
        CALL public.refresh_continuous_aggregate(r.table_schema || '.' || r.table_name, current_timestamp - 3 * _refresh_interval, current_timestamp);
        COMMIT; -- Commit after every refresh to avoid high I/O & mem-buffering.
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.caggs_refresher IS 'caggs_refresher runs every refresh_interval passed in config. Its
main aim is to refresh those Caggs that have been registered under _prom_catalog.metric and whose view_refresh_interval
matches the given refresh_interval. It refreshes 2 kinds of Caggs:
1. Caggs created by metric rollups
2. Custom Caggs created by the user';

CREATE OR REPLACE PROCEDURE _prom_catalog.create_cagg_refresh_job(_refresh_interval INTERVAL) AS
$$
BEGIN
    IF (
        SELECT EXISTS (
            SELECT 1 FROM timescaledb_information.jobs WHERE
               proc_name = 'caggs_refresher' AND schedule_interval = _refresh_interval
        )
    ) THEN
        -- Refresh job exists for the given _refresh_interval. Hence, nothing to do.
        RETURN;
    END IF;
    PERFORM public.add_job('_prom_catalog.caggs_refresher', _refresh_interval, FORMAT('{"refresh_interval": "%s"}', _refresh_interval)::jsonb);
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.create_cagg_refresh_job(INTERVAL) IS
'Creates a Cagg refresh job that refreshes all Caggs registered by register_metric_view().
This function creates a refresh job only if no caggs_refresher() exists currently with the given refresh_interval.';

-- TODO for discussion on upgrade path:
-- We cannot compress existing Caggs that the user has created since they do not have timescaledb.compress = true.
-- Hence, the todos are:
-- 1. We need an upgrade script for existing Caggs in the system that applies timescaledb.compress = true
-- 2. In the docs [https://docs.timescale.com/promscale/latest/downsample-data/caggs/] write the command to add timescaledb.compress = true
CREATE OR REPLACE PROCEDURE _prom_catalog.caggs_compressor(job_id int, config jsonb) AS
$$
DECLARE
    r RECORD;
    _rollup RECORD;
    _temp INTEGER;
    _chunks_compressed INTEGER := 0;

BEGIN
    FOR _rollup IN
        SELECT resolution FROM _prom_catalog.rollup
    LOOP
        FOR r IN
            SELECT m.table_schema || '.' || m.table_name AS compressible_cagg FROM
                _prom_catalog.metric m
            INNER JOIN
                timescaledb_information.continuous_aggregates cagg
            ON (m.table_name = cagg.view_name AND m.table_schema = cagg.view_schema)
            WHERE
                m.is_view IS true AND m.view_refresh_interval = _rollup.resolution AND cagg.compression_enabled IS TRUE
        LOOP
            SELECT count(*) INTO _temp FROM (SELECT public.compress_chunk(public.show_chunks(r.compressible_cagg, older_than => 1000 * _rollup.resolution))) a;
            _chunks_compressed := _chunks_compressed + _temp;
        END LOOP;
    END LOOP;
    RAISE WARNING 'Caggs compressor: Compressed % chunks', _chunks_compressed;
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.caggs_compressor IS 'caggs_compressor is responsible to compress continuous aggregates registered via
register_metric_view(). These include metric-rollups and custom Caggs based downsampling.
Note: caggs_compressor runs every X interval and compresses inactive chunks of only those Caggs which have timescaledb.compress = true.
By default, these include metric-rollups.';

CREATE OR REPLACE PROCEDURE _prom_catalog.caggs_retainer(job_id int, config jsonb) AS
$$
DECLARE
    r RECORD;
    _rollup RECORD;
    _temp INTEGER;
    _retention INTERVAL;
    _dropped_compressed INTEGER := 0;
    _rollup_schemas TEXT[];

BEGIN
    -- For retention, we have 2 cases:
    -- Case 1: Retention for metric-rollups
    -- These Caggs have a defined retention duration that is stored in the _prom_catalog.rollup
    --
    -- Case 2: Retention for custom Caggs
    -- These Caggs do not have a well definied policy for retention. Hence, we will assume the
    -- retention to be the retention of their parent hypertable.

    _rollup_schemas := (SELECT array_agg(schema_name) FROM _prom_catalog.rollup);

    FOR _rollup IN
        SELECT retention, resolution FROM _prom_catalog.rollup
    LOOP
        FOR r IN
            SELECT
                m.table_schema || '.' || m.table_name AS cagg,
                m.table_schema::TEXT AS _schema_name,
                m.metric_name AS _metric_name
            FROM _prom_catalog.metric m
                WHERE m.is_view IS TRUE AND m.view_refresh_interval = _rollup.resolution
        LOOP
            IF (SELECT r._schema_name = ANY(_rollup_schemas)) THEN
                -- Case 1.
                _retention := _rollup.retention;
            ELSE
                -- Case 2.
                -- Use the retention of the Cagg’s parent hypertable.
                _retention := (SELECT _prom_catalog.get_metric_retention_period(r._metric_name));
            END IF;

            SELECT count(*) INTO _temp FROM (SELECT public.drop_chunks(public.show_chunks(r.cagg, older_than => _retention))) a;
            _dropped_compressed := _dropped_compressed + _temp;
        END LOOP;
    END LOOP;
    RAISE WARNING 'Caggs retention: Dropped % chunks', _dropped_compressed;
END;
$$
LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.caggs_retainer IS 'caggs_retainer is responsible to perform retention behaviour on compress continuous aggregates registered via
register_metric_view(). These include metric-rollups and custom Caggs based downsampling.';

DO $$
DECLARE
    _is_restore_in_progress boolean = false;
    _caggs_compressor_job_already_exists boolean := false;
    _caggs_retainer_job_already_exists boolean := false;
BEGIN
    _is_restore_in_progress = coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND NOT _is_restore_in_progress
    THEN
        -- Add a caggs_compressor job if not exist.
        _caggs_compressor_job_already_exists = (SELECT EXISTS(SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'caggs_compressor')::boolean);
        IF NOT _caggs_compressor_job_already_exists THEN
            PERFORM public.add_job('_prom_catalog.caggs_compressor', INTERVAL '30 minutes');
        END IF;

        -- Add a caggs_retainer job if not exist.
        _caggs_retainer_job_already_exists = (SELECT EXISTS(SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'caggs_retainer')::boolean);
        IF NOT _caggs_retainer_job_already_exists THEN
            PERFORM public.add_job('_prom_catalog.caggs_retainer', INTERVAL '30 minutes');
        END IF;
    END IF;
END;
$$;
