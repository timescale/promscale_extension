-- Metric rollup creation by metric type
CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_gauge(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
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
            ', rollup_schema, table_name, 'UTC', resolution::text);
    EXECUTE FORMAT('ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)', rollup_schema, table_name);
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_counter(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
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
            ', rollup_schema, table_name, 'UTC', resolution::text);
    EXECUTE FORMAT('ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)', rollup_schema, table_name);
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_summary(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
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
            ', rollup_schema, table_name, 'UTC', resolution::text);
    EXECUTE FORMAT('ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)', rollup_schema, table_name);
END;
$$
LANGUAGE PLPGSQL;

-- create_metric_rollup_view decides which rollup query should be used for creation of the given rollup metric depending of metric type
-- and calls the respective creation function. It returns true if metric rollup was created.
CREATE OR REPLACE FUNCTION _prom_catalog.create_metric_rollup_view(_rollup_schema TEXT, _metric_name TEXT, _table_name TEXT, _resolution INTERVAL)
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    _metric_type TEXT;

BEGIN
   SELECT type INTO _metric_type FROM _prom_catalog.metadata WHERE metric_family = _metric_name;
    IF _metric_type IS NULL THEN
        RAISE DEBUG '[Rollup] Skipping creation of metric rollup for %. REASON: metric_type not found', _metric_name;
        RETURN FALSE;
    END IF;

    CASE
        WHEN _metric_type = 'GAUGE' THEN
            CALL _prom_catalog.create_rollup_for_gauge(_rollup_schema, _table_name, _resolution);
        WHEN _metric_type = 'COUNTER' OR _metric_type = 'HISTOGRAM' THEN
            CALL _prom_catalog.create_rollup_for_counter(_rollup_schema, _table_name, _resolution);
        WHEN _metric_type = 'SUMMARY' THEN
            CALL _prom_catalog.create_rollup_for_summary(_rollup_schema, _table_name, _resolution);
        ELSE
            RAISE WARNING '[Rollup] Skipping creation of metric rollup for %. REASON: invalid metric_type. Wanted {GAUGE, COUNTER, HISTOGRAM, SUMMARY}, received %', _metric_name, _metric_type;
    END CASE;
    RETURN TRUE;
END;
$$
LANGUAGE PLPGSQL;

-- scan_for_new_rollups is called in regular intervals to scan for either new metrics or for new resolution
-- and create metric rollups for them.
CREATE OR REPLACE PROCEDURE _prom_catalog.scan_for_new_rollups(job_id int, config jsonb)
AS
$$
DECLARE
    r RECORD;
    m RECORD;
    new_rollups_created INTEGER := 0;
    rollup_view_created BOOLEAN;

BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;
    IF ( SELECT prom_api.get_automatic_downsample()::BOOLEAN IS FALSE ) THEN
        RETURN;
    END IF;

    FOR r IN
        SELECT * FROM _prom_catalog.rollup
    LOOP
        rollup_view_created := FALSE;
        new_rollups_created := 0;
        FOR m IN
            SELECT id, metric_name, table_name FROM _prom_catalog.metric mt WHERE NOT is_view AND NOT EXISTS (
                SELECT 1 FROM _prom_catalog.metric_rollup mr WHERE mr.rollup_id = r.id AND mr.metric_id = mt.id
            ) ORDER BY mt.id -- Get metric names that have a pending rollup creation.
        LOOP
            SELECT INTO rollup_view_created _prom_catalog.create_metric_rollup_view(r.schema_name, m.metric_name, m.table_name, r.resolution);
            IF rollup_view_created THEN
                INSERT INTO _prom_catalog.metric_rollup(rollup_id, metric_id, refresh_pending) VALUES (r.id, m.id, TRUE);
                new_rollups_created := new_rollups_created + 1;

                -- Commit the materialized view created so that we release the parent hypertable and do not block
                -- depending tasks, such as ingestion. Otherwise, it will deadlock.
                COMMIT;
                SET LOCAL search_path = pg_catalog, pg_temp;
            END IF;
        END LOOP;
        RAISE LOG '[Rollup] Created % for rollup name %', new_rollups_created, r.name;
    END LOOP;

    COMMIT;
    SET LOCAL search_path = pg_catalog, pg_temp;

    -- Refresh the newly added rollups for entire duration of data.
    FOR r IN
        SELECT
            mr.id as metric_id,
            rollup.schema_name as schema_name,
            mt.table_name as table_name,
            rollup.resolution as resolution,
            rollup.id as rollup_id
        FROM _prom_catalog.metric_rollup mr
                 INNER JOIN _prom_catalog.rollup rollup ON (mr.rollup_id = rollup.id)
                 INNER JOIN _prom_catalog.metric mt ON (mr.metric_id = mt.id)
        WHERE mr.refresh_pending ORDER BY mt.id
    LOOP
        CALL public.refresh_continuous_aggregate(format('%I.%I', r.schema_name, r.table_name), NULL, NULL);
        UPDATE _prom_catalog.metric_rollup SET refresh_pending = FALSE WHERE id = r.metric_id;

        -- Perform the rollup registration only after we have initial data. This helps in 2 ways:
        -- 1. Prevent execute_caggs_refresh_policy() from refreshing the materialized view even before it is
        --      refreshed for the first time ,i.e., from start to end of the hypertable
        -- 2. In case of non-graceful shutdown, we will successfully register the non-registered rollups the
        --      next time this procedure is called. Earlier, this was done using temp table, which did not
        --      provide this guarantee
        PERFORM prom_api.register_metric_view(r.schema_name, r.table_name, r.resolution, false, r.rollup_id);
        COMMIT;
        SET LOCAL search_path = pg_catalog, pg_temp;
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;

-- create_metric_rollup prepares the given rollup. The actual rollup views are created by _prom_catalog.scan_for_new_rollups()
CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup(_name TEXT, _resolution INTERVAL, _retention INTERVAL)
    SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE
        _schema_name constant TEXT := 'ps_' || _name;
        _exists BOOLEAN;

    BEGIN
        SELECT EXISTS( SELECT 1 FROM _prom_catalog.rollup WHERE name = _name) INTO _exists;
        IF _exists THEN
            RAISE EXCEPTION 'ERROR: cannot create metric rollup for %. REASON: already exists.', _name;
        END IF;
        -- We do not use IF NOT EXISTS (below) since we want to stop creation process if the schema already exists.
        -- This forces the user to delete the conflicting schema before proceeding ahead.
        EXECUTE FORMAT('CREATE SCHEMA %I', _schema_name);
        INSERT INTO _prom_catalog.rollup(name, schema_name, resolution, retention) VALUES (_name, _schema_name, _resolution, _retention);
    END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.create_rollup(text, interval, interval) TO prom_writer;

-- delete_metric_rollup deletes everything related to the given metric rollup label name. It does the following:
-- 1. Delete the entries in _prom_catalog.rollup
-- 2. Delete the entries in _prom_catalog.metric_rollup
-- 3. Delete the actual Cagg views that represent the rollups. This is done by directing deleting the entire rollup schema
CREATE OR REPLACE PROCEDURE _prom_catalog.delete_rollup(_rollup_name TEXT)
    SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE
        _rollup_id INTEGER;
        _rollup_schema_name TEXT;

    BEGIN
        SELECT id, schema_name INTO _rollup_id, _rollup_schema_name FROM _prom_catalog.rollup WHERE name = _rollup_name;
        IF _rollup_id IS NULL THEN
            RAISE EXCEPTION '% rollup not found', _rollup_name;
        END IF;
        DELETE FROM _prom_catalog.metric WHERE rollup_id = _rollup_id; -- Delete all entries that were created due to this _rollup_name.
        DELETE FROM _prom_catalog.metric_rollup WHERE rollup_id = _rollup_id;
        DELETE FROM _prom_catalog.rollup WHERE id = _rollup_id;
        EXECUTE FORMAT('DROP SCHEMA %I CASCADE', _rollup_schema_name);
    END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.delete_rollup(text) TO prom_writer;

CREATE OR REPLACE FUNCTION prom_api.set_automatic_downsample(_state BOOLEAN)
RETURNS BOOLEAN
VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.set_default_value('automatic_downsample', _state::text);
    SELECT true;
$$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.set_automatic_downsample(BOOLEAN)
    IS 'Set automatic downsample state for metrics (a.k.a. metric rollups). Metric rollups will be created only if this returns true';
GRANT EXECUTE ON FUNCTION prom_api.set_automatic_downsample(BOOLEAN) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.get_automatic_downsample()
RETURNS BOOLEAN
SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_default_value('automatic_downsample')::boolean;
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.get_automatic_downsample()
    IS 'Get automatic downsample state for metrics (a.k.a. metric rollups)';
GRANT EXECUTE ON FUNCTION prom_api.get_automatic_downsample() TO prom_admin;

DO $$
DECLARE
    _is_restore_in_progress boolean = false;
    _rollup_creation_job_already_exists boolean := false;
BEGIN
    _is_restore_in_progress = coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND NOT _is_restore_in_progress
    THEN
        _rollup_creation_job_already_exists = (SELECT EXISTS(SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'scan_for_new_rollups')::boolean); -- prevents from registering 2 scan jobs.
        IF NOT _rollup_creation_job_already_exists THEN
            -- Scan and create metric rollups regularly for pending metrics.
            PERFORM public.add_job('_prom_catalog.scan_for_new_rollups', INTERVAL '30 minutes');
        END IF;
    END IF;
END;
$$;

-- TODO: Temporary utilities for creation of metric rollups. These MUST be removed once we have SQL aggregate in Rust,
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
