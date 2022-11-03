-- Functions under this file are responsible for maintenance of metric rollups. This maintenance task
-- is divided into 3 parts:
--
-- TODO these comments
-- 1. Refresh
-- 2. Compression
-- 3. Retention
--
-- Each of the above tasks have their respective jobs such that they work/perform their task across
-- all the resolutions (a.k.a. schemas).

CREATE OR REPLACE PROCEDURE _prom_catalog.caggs_refresher(job_id int, config jsonb) AS
$$
DECLARE
    _refresh_interval INTERVAL := config ->> 'refresh_interval';
    _schema_name TEXT;
    _table_name TEXT;
    r RECORD;

BEGIN
    FOR r IN
        SELECT table_schema, table_name INTO _schema_name, _table_name FROM _prom_catalog.metric
           WHERE is_view = TRUE AND view_refresh_interval = _refresh_interval
    LOOP
        CALL public.refresh_continuous_aggregate(_schema_name || '.' || _table_name, current_timestamp - 2 * _refresh_interval, current_timestamp);
        COMMIT; -- Commit after every refresh to avoid high I/O & mem-buffering.
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;

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
'Creates a Cagg refresh job that refreshes all Caggs registered by register_metric_view(). This function creates a refresh job only if no caggs_refresher() exists currently with the given refresh_interval';












-- *************************************************************************************************************************************************

CREATE OR REPLACE PROCEDURE _prom_catalog.rollup_refresh(job_id int, config jsonb)
AS
$$
DECLARE
    _rollup_name TEXT := config ->> 'rollup_name';
    _schema_name TEXT;
    _resolution INTERVAL;
    _rollup_id BIGINT;
    _table_name TEXT;
    r RECORD;

BEGIN
    -- todo: Refresh only if `downsample: true`
    IF _rollup_name IS NULL THEN
        RAISE EXCEPTION 'ERROR: Cannot refresh rollups as rollup_name is NULL';
    END IF;

    SELECT id::BIGINT, resolution::INTERVAL, schema_name::TEXT INTO _rollup_id, _resolution, _schema_name FROM _prom_catalog.rollup WHERE name = _rollup_name;
    IF _resolution IS NULL THEN
        RAISE EXCEPTION 'ERROR: Cannot refresh rollups under % schema since resolution is NULL', _schema_name;
    END IF;

    FOR r IN
        SELECT metric_id FROM _prom_catalog.metric_rollup WHERE rollup_id = _rollup_id
    LOOP
        SELECT table_name INTO _table_name FROM _prom_catalog.metric WHERE id = r.metric_id;
        IF _table_name IS NULL THEN
            RAISE WARNING 'Skipping refresh as no table_name found for % metric id', r.metric_id;
            CONTINUE;
        END IF;

        -- Refresh the previous 2 buckets excluding the current active bucket. This keeps the calculated results same.
        CALL public.refresh_continuous_aggregate(_schema_name || '.' || _table_name, current_timestamp - 3 * _resolution, current_timestamp - _resolution);
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION _prom_catalog.pending_rollup_chunks_for_compression(_rollup_schema TEXT, _rollup_table TEXT, _older_than INTERVAL)
RETURNS TABLE ( chunk_name REGCLASS ) AS
$$
    SELECT
        a.compressible AS chunk_name
    FROM
        (
            SELECT (schema_name || '.' || table_name)::REGCLASS AS compressible FROM _timescaledb_catalog.chunk
            WHERE hypertable_id = (
                SELECT mat_hypertable_id FROM _timescaledb_catalog.continuous_agg WHERE user_view_schema = _rollup_schema AND user_view_name = _rollup_table
            ) AND compressed_chunk_id IS NULL
        ) a
            INNER JOIN
        show_chunks(
            _rollup_schema || '.' || _rollup_table,
            older_than => _older_than
        ) b
            ON (a.compressible = b);
$$
LANGUAGE SQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.rollup_compress(job_id int, config jsonb)
AS
$$
DECLARE
    r RECORD;
    _resolution INTERVAL;
    _schema TEXT;
    _table TEXT;
BEGIN
    FOR r IN
        SELECT rollup_id, metric_id FROM _prom_catalog.metric_rollup
    LOOP
        SELECT schema_name::TEXT, resolution::INTERVAL INTO _schema, _resolution FROM _prom_catalog.rollup WHERE id = r.rollup_id;
        SELECT table_name::TEXT INTO _table FROM _prom_catalog.metric WHERE id = r.metric_id;

        PERFORM public.compress_chunk(
            _prom_catalog.pending_rollup_chunks_for_compression(_schema, _table, 1000 * _resolution)
        );
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.rollup_retention(job_id int, config jsonb)
AS
$$
DECLARE

$$
LANGUAGE PLPGSQL;
