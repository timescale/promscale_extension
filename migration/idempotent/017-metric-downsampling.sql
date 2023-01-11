-- Metric downsampling by metric type
CREATE OR REPLACE PROCEDURE _prom_catalog.downsample_gauge(_schema TEXT, _table_name TEXT, _interval INTERVAL)
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    EXECUTE FORMAT(
        'CREATE MATERIALIZED VIEW %1$I.%2$I WITH (timescaledb.continuous, timescaledb.materialized_only=true) AS
            SELECT
                timezone(
                    %3$L,
                    public.time_bucket(%4$L, time) AT TIME ZONE %3$L + %4$L
                ) as time,
                series_id,
                sum(value) as sum,
                count(value) as count,
                min(value) as min,
                max(value) as max
            FROM prom_data.%2$I
            GROUP BY public.time_bucket(%4$L, time), series_id WITH NO DATA
    ', _schema, _table_name, 'UTC', _interval::text);
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE _prom_catalog.downsample_counter(_schema TEXT, _table_name TEXT, _interval INTERVAL)
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    EXECUTE FORMAT(
        'CREATE MATERIALIZED VIEW %1$I.%2$I WITH (timescaledb.continuous, timescaledb.materialized_only=true) AS
            SELECT
                timezone(
                    %3$L,
                    public.time_bucket(%4$L, time) AT TIME ZONE %3$L + %4$L
                ) as time,
                series_id,
                public.first(value, time),
                public.last(value, time) + _prom_catalog.counter_reset_sum(array_agg(value)) last,
                _prom_catalog.irate(array_agg(value)) irate
            FROM prom_data.%2$I
            GROUP BY public.time_bucket(%4$L, time), series_id WITH NO DATA
    ', _schema, _table_name, 'UTC', _interval::text);
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.downsample_summary(_schema TEXT, _table_name TEXT, _interval INTERVAL)
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    EXECUTE FORMAT(
        'CREATE MATERIALIZED VIEW %1$I.%2$I WITH (timescaledb.continuous, timescaledb.materialized_only=true) AS
            SELECT
                timezone(
                    %3$L,
                    public.time_bucket(%4$L, time) AT TIME ZONE %3$L + %4$L
                ) as time,
                series_id,
                sum(value) as sum,
                count(value) as count
            FROM prom_data.%2$I
            GROUP BY public.time_bucket(%4$L, time), series_id WITH NO DATA
    ', _schema, _table_name, 'UTC', _interval::text);
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.add_compression_clause_to_downsample_view(_schema TEXT, _table_name TEXT)
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    EXECUTE FORMAT($sql$
        ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)
    $sql$, _schema, _table_name);
END;
$$
LANGUAGE PLPGSQL;

-- This creates a view that acts as a interface between connector and the downsampled data while querying.
-- We need this primarily for PromQL querying. Downsampled data does not contain the default column "value"
-- that connector's SQL query needs, when querying a downsampling view. Hence, to avoid complexity of code
-- on the connector side ("value" columns differs depending on metric type), we create a view that internally
-- maps to the right column of downsampled data.
CREATE OR REPLACE FUNCTION _prom_catalog.create_default_downsampling_query_view(_schema TEXT, _table_name TEXT, _default_column TEXT)
RETURNS VOID
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    -- We prefix with q_ to avoid collision with names of materialized views. This prefix can be added
    -- on the connector side.
    query TEXT := 'CREATE OR REPLACE VIEW %1$I.q_%2$I AS SELECT time, series_id, %3$s AS value FROM %1$I.%2$I';

BEGIN
    EXECUTE FORMAT(query, _schema, _table_name, _default_column);
END;
$$
LANGUAGE PLPGSQL;


-- create_metric_downsampling_view decides which query should be used for downsampling the given metric depending of metric type
-- and calls the respective creation function. It returns true if metric downsampling view was created.
CREATE OR REPLACE FUNCTION _prom_catalog.create_metric_downsampling_view(_schema TEXT, _metric_name TEXT, _table_name TEXT, _interval INTERVAL)
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    _metric_type TEXT;
    _default_query_column TEXT := 'sum / count';

BEGIN
    SELECT type INTO _metric_type FROM _prom_catalog.metadata WHERE metric_family = _metric_name;
    IF (_metric_type IS NULL) THEN
        -- Guess the metric type based on the metric_name suffix.
        IF ( SELECT _metric_name like '%_bucket') THEN
            _metric_type := 'HISTOGRAM';
        ELSIF (SELECT (_metric_name like '%_sum') OR (_metric_name like '%_count')) THEN
            _metric_type := 'COUNTER';
        ELSE
            _metric_type := 'GAUGE';
        END IF;
        RAISE WARNING '[Downsampling] Metric type of % missing. Guessed the metric-type as %', _metric_name, _metric_type;
    END IF;

    CASE
        WHEN _metric_type = 'GAUGE' THEN
            CALL _prom_catalog.downsample_gauge(_schema, _table_name, _interval);
        WHEN _metric_type = 'COUNTER' OR _metric_type = 'HISTOGRAM' THEN
            CALL _prom_catalog.downsample_counter(_schema, _table_name, _interval);
            _default_query_column := 'last';
        WHEN _metric_type = 'SUMMARY' THEN
            CALL _prom_catalog.downsample_summary(_schema, _table_name, _interval);
        ELSE
            RAISE WARNING '[Downsampling] Skipping creation of metric downsampling for %. REASON: invalid metric_type. Wanted {GAUGE, COUNTER, HISTOGRAM, SUMMARY}, received %', _metric_name, _metric_type;
            RETURN FALSE;
    END CASE;
    CALL _prom_catalog.add_compression_clause_to_downsample_view(_schema, _table_name);
    PERFORM _prom_catalog.create_default_downsampling_query_view(_schema, _table_name, _default_query_column);
    RETURN TRUE;
END;
$$
LANGUAGE PLPGSQL;

-- scan_for_new_downsampling_views is called in regular intervals to scan for either new metrics or for new downsampling configs
-- and create metric downsampling for them.
CREATE OR REPLACE PROCEDURE _prom_catalog.scan_for_new_downsampling_views(job_id int, config jsonb)
AS
$$
DECLARE
    d RECORD;
    m RECORD;
    downsampling_view_count INTEGER := 0;
    downsampling_view_created BOOLEAN;
    refresh_existing_data BOOLEAN := (SELECT prom_api.get_downsample_old_data()::boolean);

BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;
    IF ( SELECT prom_api.get_global_downsampling_state()::BOOLEAN IS FALSE ) THEN
        RETURN;
    END IF;

    FOR d IN
        SELECT * FROM _prom_catalog.downsample
    LOOP
        downsampling_view_created := FALSE;
        downsampling_view_count := 0;
        FOR m IN
            SELECT id, metric_name, table_name FROM _prom_catalog.metric mt WHERE NOT is_view AND NOT EXISTS (
                SELECT 1 FROM _prom_catalog.metric_downsample md WHERE md.downsample_id = d.id AND md.metric_id = mt.id
            ) ORDER BY mt.id -- Get metric names that have a pending downsampling creation.
        LOOP
            SELECT INTO downsampling_view_created _prom_catalog.create_metric_downsampling_view(d.schema_name, m.metric_name, m.table_name, d.ds_interval);
            IF downsampling_view_created THEN
                INSERT INTO _prom_catalog.metric_downsample(downsample_id, metric_id, refresh_pending) VALUES (d.id, m.id, TRUE);
                downsampling_view_count := downsampling_view_count + 1;

                -- Commit the materialized view created so that we release the parent hypertable and do not block
                -- depending tasks, such as ingestion. Otherwise, it will deadlock.
                COMMIT;
                SET LOCAL search_path = pg_catalog, pg_temp;
            END IF;
        END LOOP;
        RAISE LOG '[Downsampling] Created % for downsampling schema %', downsampling_view_count, d.schema_name;
    END LOOP;

    COMMIT;
    SET LOCAL search_path = pg_catalog, pg_temp;

    -- Refresh and register the newly added downsampling views.
    -- The code below works with non-graceful shutdowns.
    FOR d IN
        SELECT
            md.id as metric_downsample_id,
            dwn.schema_name as schema_name,
            mt.table_name as table_name,
            dwn.ds_interval as ds_interval,
            dwn.id as downsample_id
        FROM _prom_catalog.metric_downsample md
                 INNER JOIN _prom_catalog.downsample dwn ON (md.downsample_id = dwn.id)
                 INNER JOIN _prom_catalog.metric mt ON (md.metric_id = mt.id)
        WHERE md.refresh_pending ORDER BY mt.id
    LOOP
        IF refresh_existing_data THEN
            CALL public.refresh_continuous_aggregate(format('%I.%I', d.schema_name, d.table_name), NULL, NULL);
        END IF;

        UPDATE _prom_catalog.metric_downsample SET refresh_pending = FALSE WHERE id = d.metric_downsample_id;

        -- Perform the downsampling view registration only after we have initial data. This helps in 2 ways:
        -- 1. Prevent execute_caggs_refresh_policy() from refreshing the materialized view even before it is
        --      refreshed for the first time ,i.e., from start to end of the hypertable
        -- 2. In case of non-graceful shutdown, we will successfully register the non-registered downsampling views the
        --      next time this procedure is called. Earlier, this was done using temp table, which did not
        --      provide this guarantee
        PERFORM prom_api.register_metric_view(d.schema_name, d.table_name, d.ds_interval, false, d.downsample_id);
        COMMIT;
        SET LOCAL search_path = pg_catalog, pg_temp;
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;

-- apply_downsample_config does 2 things:
-- 1. Create new downsampling configurations based on the given config
-- 2. Update the existing downsampling config in terms of retention, enabling/disabling downsampling config
-- The given config must be an array of <schema_name, ds_interval, retention>
CREATE OR REPLACE FUNCTION _prom_catalog.apply_downsample_config(config jsonb)
RETURNS VOID
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    _input _prom_catalog.downsample[];
    _schema_name TEXT;

BEGIN
    SELECT array_agg(x) INTO STRICT _input FROM jsonb_populate_recordset(NULL::_prom_catalog.downsample, config) x;

    FOR _schema_name IN
        SELECT a.schema_name FROM unnest(_input) a WHERE NOT EXISTS(
            SELECT 1 FROM _prom_catalog.downsample d WHERE d.schema_name = a.schema_name
        )
    LOOP
        EXECUTE format('create schema %I', _schema_name);
    END LOOP;

    -- Insert or update the retention duration and enable the downsampling if disabled.
    INSERT INTO _prom_catalog.downsample (schema_name, ds_interval, retention, should_refresh)
        SELECT a.schema_name, a.ds_interval, a.retention, TRUE FROM unnest(_input) a
            ON CONFLICT (schema_name) DO UPDATE
                SET
                    retention = excluded.retention,
                    should_refresh = TRUE;

    -- Disable downsampling if existing configs does not exists in the incoming config.
    UPDATE _prom_catalog.downsample SET should_refresh = false WHERE schema_name NOT IN (
        SELECT schema_name FROM unnest(_input)
    );
END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.apply_downsample_config(jsonb) TO prom_writer;

-- delete_downsampling deletes everything related to the given downsampling schema name. It does the following in order:
-- 1. Delete the entries in _prom_catalog.downsample
-- 2. Delete the entries in _prom_catalog.metric_downsample
-- 3. Delete the actual Cagg views that represent the downsampled data. This is done by directing deleting the entire downsampled schema
CREATE OR REPLACE PROCEDURE _prom_catalog.delete_downsampling(_schema_name TEXT)
    SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE
        _downsample_id INTEGER;

    BEGIN
        SELECT id INTO _downsample_id FROM _prom_catalog.downsample WHERE schema_name = _schema_name;
        IF _downsample_id IS NULL THEN
            RAISE EXCEPTION 'downsampling with % schema not found', _schema_name;
        END IF;
        DELETE FROM _prom_catalog.metric WHERE downsample_id = _downsample_id; -- Delete all entries that were created due to this _downsample_id
        DELETE FROM _prom_catalog.metric_downsample WHERE downsample_id = _downsample_id;
        DELETE FROM _prom_catalog.downsample WHERE id = _downsample_id;
        EXECUTE FORMAT('DROP SCHEMA %I CASCADE', _schema_name);
    END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.delete_downsampling(text) TO prom_writer;

CREATE OR REPLACE FUNCTION prom_api.set_global_downsampling_state(_state BOOLEAN)
RETURNS VOID
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.set_default_value('downsample', _state::text);
$$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.set_global_downsampling_state(BOOLEAN)
    IS 'Set automatic-downsampling state for metrics. Downsampled data will be created only if this returns true';
GRANT EXECUTE ON FUNCTION prom_api.set_global_downsampling_state(BOOLEAN) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.get_global_downsampling_state()
RETURNS BOOLEAN
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.get_default_value('downsample')::boolean;
$$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.get_global_downsampling_state()
    IS 'Get automatic downsample state';
GRANT EXECUTE ON FUNCTION prom_api.get_global_downsampling_state() TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_downsample_old_data(_state BOOLEAN)
RETURNS VOID
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.set_default_value('downsample_old_data', _state::text);
$$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION prom_api.set_downsample_old_data(BOOLEAN) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.get_downsample_old_data()
RETURNS BOOLEAN
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.get_default_value('downsample_old_data')::boolean;
$$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION prom_api.get_downsample_old_data() TO prom_admin;

DO $$
DECLARE
    _is_restore_in_progress boolean = false;
    _new_downsampling_creation_job_already_exists boolean := false;
BEGIN
    _is_restore_in_progress = coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND NOT _is_restore_in_progress
    THEN
        _new_downsampling_creation_job_already_exists = (SELECT EXISTS(SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'scan_for_new_downsampling_views')::boolean); -- prevents from registering 2 scan jobs.
        IF NOT _new_downsampling_creation_job_already_exists THEN
            -- Scan and create metric downsampling regularly for pending metrics.
            PERFORM public.add_job('_prom_catalog.scan_for_new_downsampling_views', INTERVAL '30 minutes');
        END IF;
    END IF;
END;
$$;

-- TODO: Temporary utilities for creation of metric downsampling. These MUST be removed once we have SQL aggregate in Rust,
-- since their behaviour is unreliable.
CREATE FUNCTION _prom_catalog.counter_reset_sum(v DOUBLE PRECISION[]) RETURNS DOUBLE PRECISION
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    reset_sum DOUBLE PRECISION := 0;
    length INTEGER := cardinality(v);
    i INTEGER := 1;
    previous DOUBLE PRECISION;

BEGIN
    IF length < 2 THEN
        RETURN 0;
    END IF;
    previous := v[1];
    FOR i IN 2..length LOOP
        IF v[i] < previous THEN
            reset_sum := reset_sum + v[i];
        END IF;
    END LOOP;
    RETURN reset_sum;
END;
$$
LANGUAGE PLPGSQL IMMUTABLE;

CREATE FUNCTION _prom_catalog.irate(v DOUBLE PRECISION[])
RETURNS DOUBLE PRECISION
    SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE
        length INTEGER := cardinality(v);

    BEGIN
        IF length < 2 THEN
            RETURN 0;
        END IF;
        return v[length] - v[length-1];
    END;
$$
LANGUAGE PLPGSQL IMMUTABLE;
