DO $doit$
 DECLARE
     r RECORD;
     _compressed_schema TEXT;
     _compressed_hypertable TEXT;
 BEGIN
     FOR r IN
         SELECT *
         FROM _prom_catalog.metric
         WHERE table_schema = 'prom_data'
     LOOP
        IF current_setting('server_version_num')::integer >= 130000 THEN
            EXECUTE FORMAT($$
                ALTER TABLE prom_data.%I SET
                (
                    autovacuum_vacuum_insert_threshold=50000,
                    autovacuum_vacuum_insert_scale_factor=2.0,
                    autovacuum_analyze_threshold = 50000,
                    autovacuum_analyze_scale_factor = 0.5
                )
            $$, r.table_name);
        ELSE
            EXECUTE FORMAT($$
                ALTER TABLE prom_data.%I SET
                (
                    autovacuum_analyze_threshold = 50000,
                    autovacuum_analyze_scale_factor = 0.5
                )
            $$, r.table_name);
        END IF;
        EXECUTE FORMAT($$ ALTER TABLE prom_data.%I RESET (autovacuum_vacuum_threshold) $$, r.table_name);

        SELECT c.schema_name, c.table_name
        INTO _compressed_schema, _compressed_hypertable
        FROM _timescaledb_catalog.hypertable h
        INNER JOIN _timescaledb_catalog.hypertable c ON (h.compressed_hypertable_id= c.id)
        WHERE h.schema_name = 'prom_data' AND h.table_name = r.table_name;

        CONTINUE WHEN NOT FOUND;

        IF current_setting('server_version_num')::integer >= 130000 THEN
            EXECUTE FORMAT($$
                ALTER TABLE %I.%I SET
                (
                    autovacuum_freeze_min_age=0,
                    autovacuum_freeze_table_age=0,
                    autovacuum_vacuum_insert_threshold=1,
                    autovacuum_vacuum_insert_scale_factor=0.0
                )
            $$, _compressed_schema, _compressed_hypertable);
        ELSE
            EXECUTE FORMAT($$
                ALTER TABLE %I.%I SET
                (
                    autovacuum_freeze_min_age=0,
                    autovacuum_freeze_table_age=0
                )
            $$, _compressed_schema, _compressed_hypertable);
        END IF;
     END LOOP;
 END
 $doit$;