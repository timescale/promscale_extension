ALTER TABLE _prom_catalog.metric ADD COLUMN default_compress_chunk_interval BOOLEAN NOT NULL DEFAULT true;

-- Set chunk interval and compress chunk interval to new defaults.
-- Chunk interval will only be updated if it is set to the previous initial a.k.a. non-user default.
DO $$
DECLARE
    r RECORD;
    _chunk_time_initial_default TEXT;
    _previous_chunk_time_initial_default TEXT = (INTERVAL '8 hours')::TEXT;
    _chunk_time_interval INTERVAL;
BEGIN
    SELECT coalesce(d.value, _previous_chunk_time_initial_default)
    INTO _chunk_time_initial_default
    FROM _prom_catalog.default d 
    WHERE d.key = 'chunk_interval';

    IF NOT FOUND THEN
        _chunk_time_initial_default := _previous_chunk_time_initial_default;
    END IF;

    IF NOT _prom_catalog.is_timescaledb_oss()
        THEN

        FOR r IN
            SELECT *
            FROM _prom_catalog.metric m
            WHERE NOT m.is_view
        LOOP
            IF _chunk_time_initial_default = _previous_chunk_time_initial_default
            AND r.default_chunk_interval
            THEN
                SELECT INTERVAL '1 hour' * (1.0+((random()*0.01)-0.005))
                INTO STRICT _chunk_time_interval;

                EXECUTE public.set_chunk_time_interval(
                    format('prom_data.%I', r.table_name),
                    _chunk_time_interval
                );
            ELSE 
                SELECT time_interval
                INTO STRICT _chunk_time_interval
                FROM _prom_catalog.metric m
                INNER JOIN timescaledb_information.dimensions d 
                ON m.table_name = d.hypertable_name 
                AND m.table_schema = d.hypertable_schema
                WHERE m.metric_name = r.metric_name
                AND d.column_name = 'time';
            END IF;

            BEGIN
                EXECUTE format($query$
                    ALTER TABLE prom_data.%I SET (
                        timescaledb.compress_chunk_time_interval = '%s'
                    ) $query$, 
                    r.table_name, 
                    (FLOOR(EXTRACT(EPOCH FROM INTERVAL '24 hours')/EXTRACT(EPOCH FROM _chunk_time_interval)) * _chunk_time_interval)::text
                    );
                EXCEPTION WHEN SQLSTATE '01000' THEN
            END;
        END LOOP;
    END IF;
END
$$;
