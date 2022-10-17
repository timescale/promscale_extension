-- create_metric_rollup prepares the given rollup. The actual rollup views are created by _prom_catalog.scan_for_new_rollups()
CREATE OR REPLACE PROCEDURE _prom_catalog.create_metric_rollup(name TEXT, resolution INTERVAL, retention INTERVAL) AS
$$
    DECLARE
        schema_name TEXT := 'ps_' || name;
        exists BOOLEAN;

    BEGIN
        EXECUTE FORMAT('SELECT count(*) > 0 FROM _prom_catalog.rollup WHERE name = %L', name) INTO exists;
        IF exists THEN
            RAISE EXCEPTION 'ERROR: cannot create metric rollup for %. REASON: already exists.', name;
        END IF;
        -- We do not use IF NOT EXISTS (below) since we want to stop creation process if the schema already exists.
        -- This forces the user to delete the conflicting schema before proceeding ahead.
        EXECUTE FORMAT('CREATE SCHEMA %s', schema_name);
        INSERT INTO _prom_catalog.rollup VALUES (name, schema_name, resolution, retention);
    END;
$$
LANGUAGE PLPGSQL;

-- scan_for_new_rollups is called in regular intervals to scan for either new metrics or for new resolution
-- and create metric rollups for them.
CREATE OR REPLACE PROCEDURE _prom_catalog.scan_for_new_rollups(job_id int, config jsonb) AS
$$
DECLARE
    r RECORD;
    m RECORD;
    new_rollups_created INTEGER := 0;
    rollup_view_created BOOLEAN;

BEGIN
    IF ( SELECT _prom_catalog.get_default_value('metric_rollup') IS NULL OR _prom_catalog.get_default_value('metric_rollup') = 'false' ) THEN
        RETURN;
    END IF;

    FOR r IN
        SELECT * FROM _prom_catalog.rollup
    LOOP
        rollup_view_created := FALSE;
        new_rollups_created := 0;
        FOR m IN
            EXECUTE FORMAT('select metric_name, table_name FROM _prom_catalog.metric where metric_name NOT IN (
                SELECT metric_name FROM _prom_catalog.metric_with_rollup WHERE rollup_schema = %L
            )', r.schema_name) -- Get metric names that have a pending rollup creation.
        LOOP
            SELECT INTO rollup_view_created _prom_catalog.create_metric_rollup_view(r.schema_name, m.metric_name, m.table_name, r.resolution);
            IF rollup_view_created THEN
                EXECUTE FORMAT('INSERT INTO _prom_catalog.metric_with_rollup VALUES (%L, %L, %L, TRUE)', r.schema_name, m.metric_name, m.table_name);
                new_rollups_created := new_rollups_created + 1;
            END IF;
        END LOOP;
        RAISE LOG '[Rollup] Created % for rollup name %', new_rollups_created, r.name;
    END LOOP;

    COMMIT;

    -- Refresh the newly added rollups for entire duration of data.
    FOR r IN
        SELECT rollup_schema, table_name FROM _prom_catalog.metric_with_rollup WHERE refresh_pending = TRUE
    LOOP
        CALL refresh_continuous_aggregate(r.rollup_schema || '.' || r.table_name, NULL, NULL);
        UPDATE _prom_catalog.metric_with_rollup SET refresh_pending = FALSE WHERE rollup_schema = r.rollup_schema AND table_name = r.table_name;
    END LOOP;
END;
$$
LANGUAGE PLPGSQL;

DO $$
BEGIN
    -- Scan and create metric rollups regularly for pending metrics.
    PERFORM public.add_job('_prom_catalog.scan_for_new_rollups', INTERVAL '30 minutes');
END;
$$;

-- create_metric_rollup_view decides which rollup query should be used for creation of the given rollup metric depending of metric type
-- and calls the respective creation function. It returns true if metric rollup was created.
CREATE OR REPLACE FUNCTION _prom_catalog.create_metric_rollup_view(rollup_schema TEXT, metric_name TEXT, table_name TEXT, resolution INTERVAL)
RETURNS BOOLEAN AS
$$
    DECLARE
        metric_type TEXT;

    BEGIN
        EXECUTE FORMAT('SELECT type FROM _prom_catalog.metadata WHERE metric_family = %L', metric_name) INTO metric_type;
        IF metric_type IS NULL THEN
            RAISE DEBUG '[Rollup] Skipping creation of metric rollup for %. REASON: metric_type not found', metric_name;
            RETURN FALSE;
        END IF;

        CASE
            WHEN metric_type = 'GAUGE' THEN
                CALL _prom_catalog.create_rollup_for_gauge(rollup_schema, table_name, resolution);
            WHEN metric_type = 'COUNTER' OR metric_type = 'HISTOGRAM' THEN
                CALL _prom_catalog.create_rollup_for_counter(rollup_schema, table_name, resolution);
            WHEN metric_type = 'SUMMARY' THEN
                CALL _prom_catalog.create_rollup_for_summary(rollup_schema, table_name, resolution);
            ELSE
                RAISE WARNING '[Rollup] Skipping creation of metric rollup for %. REASON: invalid metric_type. Wanted {GAUGE, COUNTER, HISTOGRAM, SUMMARY}, received %', metric_name, metric_type;
            END CASE;
        RETURN TRUE;
    END;
$$
LANGUAGE PLPGSQL;

-- TODO: Temporary utilities for creation of metric rollups. These MUST be removed once we have SQL aggregate in Rust,
-- since their behaviour is unreliable.
CREATE FUNCTION _prom_catalog.counter_reset_sum(v DOUBLE PRECISION[]) RETURNS DOUBLE PRECISION AS
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
RETURNS DOUBLE PRECISION AS
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

-- Metric rollup creation by metric type
CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_gauge(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
AS
$$
BEGIN
    EXECUTE FORMAT(
        'CREATE MATERIALIZED VIEW %1$I.%2$I WITH (timescaledb.continuous, timescaledb.materialized_only=true) AS
            SELECT
                timezone(
                    %3$L,
                    time_bucket(%4$L, time) AT TIME ZONE %3$L + %4$L
                ) as time,
                series_id,
                sum(value) as sum,
                count(value) as count,
                min(value) as min,
                max(value) as max
            FROM prom_data.%2$I
            GROUP BY time_bucket(%4$L, time), series_id WITH NO DATA
        ', rollup_schema, table_name, 'UTC', resolution::text);
    EXECUTE FORMAT('ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)', rollup_schema, table_name);
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_counter(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
AS
$$
BEGIN
    EXECUTE FORMAT(
        'CREATE MATERIALIZED VIEW %1$I.%2$I WITH (timescaledb.continuous, timescaledb.materialized_only=true) AS
            SELECT
                timezone(
                    %3$L,
                    time_bucket(%4$L, time) AT TIME ZONE %3$L + %4$L
                ) as time,
                series_id,
                first(value, time),
                last(value, time) + _prom_catalog.counter_reset_sum(array_agg(value)) last,
                _prom_catalog.irate(array_agg(value)) irate
            FROM prom_data.%2$I
            GROUP BY time_bucket(%4$L, time), series_id WITH NO DATA
        ', rollup_schema, table_name, 'UTC', resolution::text);
    EXECUTE FORMAT('ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)', rollup_schema, table_name);
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_summary(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
AS
$$
BEGIN
    EXECUTE FORMAT(
        'CREATE MATERIALIZED VIEW %1$I.%2$I WITH (timescaledb.continuous, timescaledb.materialized_only=true) AS
            SELECT
                timezone(
                    %3$L,
                    time_bucket(%4$L, time) AT TIME ZONE %3$L + %4$L
                ) as time,
                series_id,
                sum(value) as sum,
                count(value) as count
            FROM prom_data.%2$I
            GROUP BY time_bucket(%4$L, time), series_id WITH NO DATA
        ', rollup_schema, table_name, 'UTC', resolution::text);
    EXECUTE FORMAT('ALTER MATERIALIZED VIEW %1$I.%2$I SET (timescaledb.compress = true)', rollup_schema, table_name);
END;
$$
LANGUAGE PLPGSQL;
