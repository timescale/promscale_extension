-- This func prepares the given rollup. The actual rollup views are created by _prom_catalog.scan_for_new_rollups()
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
        EXECUTE FORMAT('CREATE SCHEMA IF NOT EXISTS %s', schema_name);
        PERFORM add_job('_prom_catalog.rollup_maintenance', resolution, FORMAT('{"schema_name": "%s"}', schema_name)::jsonb);
        INSERT INTO _prom_catalog.rollup VALUES (name, schema_name, resolution, retention);
    END;
$$
LANGUAGE PLPGSQL;

-- This func should be called in regular intervals to scan for either new metrics
-- or for new resolution and prepare them for metric rollup.
CREATE OR REPLACE PROCEDURE _prom_catalog.scan_for_new_rollups() AS
$$
    DECLARE
        r RECORD;
        m RECORD;
        rollup_exists BOOLEAN;
        new_rollups_created INTEGER := 0;
        rollup_view_created BOOLEAN;

    BEGIN
        FOR r IN
            SELECT * FROM _prom_catalog.rollup
        LOOP
            rollup_view_created := FALSE;
            EXECUTE FORMAT('SELECT count(*) > 0 FROM _prom_catalog.rollup WHERE name = %L', r.name) INTO rollup_exists;
            IF ( rollup_exists ) THEN
                -- Check for new metrics that are pending for this.
                FOR m IN
                    EXECUTE FORMAT('select metric_name, table_name FROM _prom_catalog.metric where metric_name NOT IN (
                        SELECT metric_name FROM _prom_catalog.metric_with_rollup WHERE rollup_schema = %L
                    )', r.schema_name)
                LOOP
                    SELECT INTO rollup_view_created _prom_catalog.create_metric_rollup_view(r.schema_name, m.metric_name, m.table_name, r.resolution);
                    IF rollup_view_created THEN
                        EXECUTE FORMAT('INSERT INTO _prom_catalog.metric_with_rollup VALUES (%L, %L, %L)', r.schema_name, m.metric_name, m.table_name);
                        new_rollups_created := new_rollups_created + 1;
                    END IF;
                END LOOP;
                RAISE WARNING 'New rollups created for rollup % => %', r.name, new_rollups_created;
                CONTINUE;
            END IF;

            -- Rollup is new. Hence, create the rollup for all metrics..
            FOR m IN
                SELECT metric_name, table_name FROM _prom_catalog.metric
            LOOP
                SELECT INTO rollup_view_created _prom_catalog.create_metric_rollup_view(r.schema_name, m.metric_name, m.table_name, r.resolution);
                IF rollup_view_created THEN
                    EXECUTE FORMAT('INSERT INTO _prom_catalog.metric_with_rollup VALUES (%L, %L, %L, TRUE)', r.schema_name, m.metric_name, m.table_name);
                    new_rollups_created := new_rollups_created + 1;
                    CALL refresh_continuous_aggregate(r.schema_name || '.' || r.table_name, NULL, NULL);
                END IF;
            END LOOP;
            RAISE WARNING 'New rollups created for rollup % => %', r.name, new_rollups_created;
        END LOOP;

        COMMIT;

        -- Refresh the newly added Caggs.
        FOR r IN
            SELECT rollup_schema, table_name FROM _prom_catalog.metric_with_rollup WHERE refresh_pending = TRUE
        LOOP
                CALL refresh_continuous_aggregate(r.rollup_schema || '.' || r.table_name, NULL, NULL);
                UPDATE _prom_catalog.metric_with_rollup SET refresh_pending = FALSE WHERE rollup_schema = r.rollup_schema AND table_name = r.table_name;
        END LOOP;
    END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE _prom_catalog.rollup_maintenance(job_id int, config jsonb) AS
$$
DECLARE
    schema_name TEXT := config ->> 'schema_name';
    refreshed_count INTEGER := 0;
    r RECORD;
    resolution INTERVAL;
    retention INTERVAL;

    dropped_chunks_count INTEGER := 0;
    compressed_chunks_count INTEGER := 0;
    temp INTEGER := 0;

BEGIN
    IF schema_name IS NULL THEN
        RAISE EXCEPTION 'ERROR: Maintenance of metric rollups not possible with job id %. REASON: schema_name is null in rollup_maintenance.', job_id;
    END IF;

    FOR r IN
        SELECT table_name FROM _prom_catalog.metric_with_rollup WHERE rollup_schema = schema_name
    LOOP
        -- Task: The maintenance jobs for metric rollups have 3 tasks to do:
        -- 1. Refresh
        -- 2. Compress
        -- 3. Retention
        EXECUTE FORMAT('SELECT resolution, retention FROM _prom_catalog.rollup WHERE schema_name = %L', schema_name) INTO resolution, retention;
        IF (resolution IS NULL OR retention IS NULL) THEN
            RAISE EXCEPTION 'Cannot perform rollup_maintenance for job id %. Reason: either resolution or retention for rollup schema % is NULL', job_id, schema_name;
        END IF;

        -- Refresh.
        CALL refresh_continuous_aggregate(schema_name || '.' || r.table_name, current_timestamp - 3 * resolution, current_timestamp - resolution);
        refreshed_count := refreshed_count + 1;

        -- Compress.
        -- Note: The rollup is refreshed every 'resolution', which means, it adds a sample every 'resolution' (as resolution is same or time_bucket),
        -- it basically means we are adding X samples for compression, for X is `X * resolution` below.
        -- Note: This query is wrong for compression. For some reason, PERFORM does not do its job properly. Replacing with SELECT works fine.
        SELECT count(*) INTO temp FROM (
            SELECT compress_chunk(
            _prom_catalog.pending_rollup_chunks_for_compression(schema_name, r.table_name, 2*resolution)
            )
        ) a;
        compressed_chunks_count := compressed_chunks_count + temp;

        -- Retention.
        SELECT count(*) INTO temp FROM (SELECT drop_chunks(schema_name || '.' || r.table_name, older_than => retention)) a;
        dropped_chunks_count := dropped_chunks_count + temp;
    END LOOP;
    raise warning '[JOB ID %] Running on % schema => Refreshed % metric rollups ; Compressed % chunks ; Dropped % chunks', job_id, schema_name, refreshed_count, compressed_chunks_count, dropped_chunks_count;
END;
$$
LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION _prom_catalog.pending_rollup_chunks_for_compression(rollup_schema TEXT, rollup_table TEXT, older_than INTERVAL)
RETURNS TABLE ( chunk_name REGCLASS ) AS
$$
    SELECT
        a.compressible AS chunk_name
    FROM
        (
            SELECT (schema_name || '.' || table_name)::REGCLASS AS compressible FROM _timescaledb_catalog.chunk
                WHERE hypertable_id = (
                    SELECT mat_hypertable_id FROM _timescaledb_catalog.continuous_agg WHERE user_view_schema = rollup_schema AND user_view_name = rollup_table
                ) AND compressed_chunk_id IS NULL
        ) a
            INNER JOIN
        show_chunks(
                'ps_1_min.go_goroutines',
                older_than => older_than
            ) b
        ON (a.compressible = b);
$$
language SQL;

-- Returns true if metric rollup was created.
CREATE OR REPLACE FUNCTION _prom_catalog.create_metric_rollup_view(rollup_schema TEXT, metric_name TEXT, table_name TEXT, resolution INTERVAL)
    RETURNS BOOLEAN AS
$$
DECLARE
    metric_type TEXT;

BEGIN
    EXECUTE FORMAT('SELECT type FROM _prom_catalog.metadata WHERE metric_family = %L', metric_name) INTO metric_type;
    IF metric_type IS NULL THEN
        RAISE WARNING 'Skipping creation of metric rollup for %. REASON: metric_type not found', metric_name;
        RETURN FALSE;
    END IF;

    CASE
        WHEN metric_type = 'GAUGE' THEN
            CALL _prom_catalog.create_rollup_for_gauge(rollup_schema, table_name, resolution);
        WHEN metric_type = 'COUNTER' OR metric_type = 'HISTOGRAM' THEN
            CALL _prom_catalog.create_rollup_for_counter(rollup_schema, table_name, resolution);
        WHEN metric_type = 'SUMMARY' THEN
            CALL _prom_catalog.create_rollup_for_summary(rollup_schema, table_name, resolution);
    END CASE;
    RETURN TRUE;
END;
$$
LANGUAGE PLPGSQL;

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
                    last(value, time) + _prom_catalog.counter_reset_sum(array_agg(value)) last_with_counter_reset
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

CREATE FUNCTION _prom_catalog.counter_reset_sum(asc_ordered_v DOUBLE PRECISION[]) RETURNS DOUBLE PRECISION AS
$$
DECLARE
    reset_sum DOUBLE PRECISION := 0;
    length INTEGER := cardinality(asc_ordered_v);
    i INTEGER := 1;
    previous DOUBLE PRECISION;

BEGIN
    IF length < 2 THEN
        RETURN 0;
    END IF;
    previous := asc_ordered_v[1];
    FOR i IN 2..length LOOP
        IF asc_ordered_v[i] < previous THEN
            reset_sum := reset_sum + asc_ordered_v[i];
        END IF;
    END LOOP;
    RETURN reset_sum;
END;
$$
LANGUAGE PLPGSQL IMMUTABLE;
