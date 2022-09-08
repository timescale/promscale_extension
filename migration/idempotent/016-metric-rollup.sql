CREATE OR REPLACE PROCEDURE _prom_catalog.create_rollup_for_gauge(rollup_schema TEXT, table_name TEXT, resolution INTERVAL)
AS
$$
    BEGIN
        execute FORMAT(
            'CREATE MATERIALIZED VIEW %1$I.%2$I AS
                SELECT
                    timezone(
                        %3$L,
                        time_bucket(%4$L::interval, time) AT TIME ZONE %3$L + %4$L::interval
                    ) as time,
                    series_id,
                    sum(value) as sum,
                    count(value) as count,
                    min(value) as min,
                    max(value) as max
                FROM prom_data.%2$I
                GROUP BY 1, 2
        ', rollup_schema, table_name, 'UTC', resolution);
    END
$$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE _prom_catalog.create_new_metric_rollups_from_pending() AS
$$
DECLARE
    rollup RECORD;
    resolution INTERVAL;
    metric_type TEXT;
    rollup_created_count INTEGER := 0;
    rollup_skipped_count INTEGER := 0;

BEGIN
    IF (SELECT count(*) = 0 FROM _prom_catalog.rollup) THEN
        -- No metric rollup task if no resolution exist.
        RAISE WARNING 'No rollup resolution found. Skipping metric rollup creation';
        RETURN;
    END IF;

    IF (SELECT count(*) = 0 FROM _prom_catalog.metric) THEN
        -- No metric exist.
        RAISE WARNING 'No metric found. Skipping metric rollup creation';
        RETURN;
    END IF;

    for rollup in
        select rollup_schema_name, metric_name, table_name FROM _prom_catalog.metric_with_rollup WHERE initialized IS FALSE
        loop
            EXECUTE FORMAT('SELECT type FROM _prom_catalog.metadata WHERE metric_family = %L', rollup.metric_name) INTO metric_type;
            IF (metric_type IS NULL) OR (metric_type <> 'GAUGE') THEN
                rollup_skipped_count := rollup_skipped_count + 1;
                CONTINUE;
            end if;

            EXECUTE FORMAT('SELECT resolution FROM _prom_catalog.rollup WHERE schema_name = %L', rollup.rollup_schema_name) INTO resolution;

            CALL _prom_catalog.create_rollup_for_gauge(rollup.rollup_schema_name, rollup.table_name, resolution);
            rollup_created_count := rollup_created_count + 1;
            EXECUTE FORMAT('UPDATE _prom_catalog.metric_with_rollup SET initialized = TRUE WHERE table_name = %L AND rollup_schema_name = %L', rollup.table_name, rollup.rollup_schema_name);
        end loop;
    raise warning 'total rollups created for "%" schema => %', rollup.rollup_schema_name, rollup_created_count;
    raise warning 'total rollups skipped => %', rollup_skipped_count;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE _prom_catalog.rollup_maintenance(job_id int, config jsonb) AS
$$
    DECLARE
        schema_name TEXT := config ->> 'schema_name';
        refreshed_count INTEGER := 0;
        r RECORD;

    BEGIN
        IF schema_name IS NULL THEN
            RAISE EXCEPTION 'ERROR: schema_name is null in rollup_maintenance';
        END IF;

        FOR r IN
            EXECUTE FORMAT('SELECT rollup_schema_name, table_name FROM _prom_catalog.metric_with_rollup WHERE initialized IS TRUE AND rollup_schema_name = %L', schema_name)
        LOOP
                EXECUTE FORMAT('REFRESH MATERIALIZED VIEW %s.%s', r.rollup_schema_name, r.table_name);
                refreshed_count := refreshed_count + 1;
        END LOOP;
        raise warning 'refreshed % metric rollups by job id %', refreshed_count, job_id;
    END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE _prom_catalog.prepare_new_pending_metric_rollups_if_any(rollup_name TEXT, resolution INTERVAL, retention INTERVAL) AS
$$
    DECLARE
        schema_name TEXT := 'ps_' || rollup_name;
        rollup_exists BOOLEAN;
        new_rollups_created INTEGER := 0;
        r RECORD;

    BEGIN
        EXECUTE FORMAT('SELECT count(*) > 0 FROM _prom_catalog.rollup WHERE name = %L', rollup_name) INTO rollup_exists;
        IF ( rollup_exists ) THEN
            -- Check for new metrics that are pending for this.
            FOR r IN
                EXECUTE FORMAT('select metric_name, table_name FROM _prom_catalog.metric where metric_name NOT IN (
                    SELECT metric_name FROM _prom_catalog.metric_with_rollup WHERE rollup_schema_name = %L
                )', schema_name)
            LOOP
                EXECUTE FORMAT('INSERT INTO _prom_catalog.metric_with_rollup VALUES (%L, %L, %L, FALSE)', schema_name, r.metric_name, r.table_name);
                new_rollups_created := new_rollups_created + 1;
            END LOOP;
            RAISE WARNING 'New rollups created for % => %', rollup_name, new_rollups_created;
            RETURN;
        END IF;

        EXECUTE FORMAT('INSERT INTO _prom_catalog.rollup VALUES (%L, %L, %L::INTERVAL, %L::INTERVAL)', rollup_name, schema_name, resolution, retention);
        EXECUTE FORMAT('CREATE SCHEMA IF NOT EXISTS %s', schema_name);

        FOR r IN
            SELECT metric_name, table_name FROM _prom_catalog.metric
        LOOP
            EXECUTE FORMAT('INSERT INTO _prom_catalog.metric_with_rollup VALUES (%L, %L, %L, FALSE)', schema_name, r.metric_name, r.table_name);
        END LOOP;

        PERFORM add_job('_prom_catalog.rollup_maintenance', resolution, FORMAT('{"schema_name": "%s"}', schema_name)::jsonb);
    END;
$$
LANGUAGE PLPGSQL;
