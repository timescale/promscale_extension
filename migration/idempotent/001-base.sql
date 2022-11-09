--NOTES
--This code assumes that table names can only be 63 chars long

CREATE OR REPLACE VIEW _prom_catalog.initial_default AS
SELECT *
FROM
(
    VALUES
    ('chunk_interval'           , (INTERVAL '8 hours')::text),
    ('retention_period'         , (90 * INTERVAL '1 day')::text),
    ('metric_compression'       , (exists(select 1 from pg_catalog.pg_proc where proname = 'compress_chunk')::text)),
    ('trace_retention_period'   , (30 * INTERVAL '1 days')::text),
    ('ha_lease_timeout'         , '1m'),
    ('ha_lease_refresh'         , '10s'),
    ('epoch_duration'           , (INTERVAL '12 hours')::text),
    ('automatic_downsample'     , 'true')
) d(key, value)
;
GRANT SELECT ON _prom_catalog.initial_default TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_default_value(_key text)
    RETURNS TEXT
    SET search_path = pg_catalog, pg_temp
AS $func$
    -- if there is a user-supplied default value, take it
    -- otherwise take the initial default value
    SELECT coalesce(d.value, dd.value)
    FROM _prom_catalog.initial_default dd
    LEFT OUTER JOIN _prom_catalog.default d ON (dd.key = d.key)
    WHERE dd.key = _key;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_default_value(text) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.set_default_value(_key text, _value text)
    RETURNS VOID
    SET search_path = pg_catalog, pg_temp
AS $func$
    INSERT INTO _prom_catalog.default (key, value)
    VALUES (_key, _value)
    ON CONFLICT (key) DO
    UPDATE SET value = excluded.value
    ;
$func$
LANGUAGE SQL VOLATILE;
GRANT EXECUTE ON FUNCTION _prom_catalog.set_default_value(text, text) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.is_restore_in_progress()
RETURNS BOOLEAN
SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false)
$func$
LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.is_restore_in_progress() TO prom_reader;

CREATE OR REPLACE PROCEDURE _prom_catalog.execute_everywhere(command_key text, command TEXT, transactional BOOLEAN = true)
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    IF command_key IS NOT NULL THEN
       INSERT INTO _prom_catalog.remote_commands(key, command, transactional) VALUES(command_key, command, transactional)
       ON CONFLICT (key) DO UPDATE SET command = excluded.command, transactional = excluded.transactional;
    END IF;

    EXECUTE command;

    -- do not call distributed_exec if we are in the middle of restoring from backup
    IF _prom_catalog.is_restore_in_progress() THEN
        RAISE NOTICE 'restore in progress. skipping %', coalesce(command_key, 'anonymous command');
        RETURN;
    END IF;
    BEGIN
        CALL public.distributed_exec(command);
    EXCEPTION
        WHEN undefined_function THEN
            -- we're not on Timescale 2, just return
            RETURN;
        WHEN SQLSTATE '0A000' THEN
            -- we're not the access node, just return
            RETURN;
    END;
END
$func$ LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.execute_everywhere(text, text, boolean) TO prom_admin;

CREATE OR REPLACE PROCEDURE _prom_catalog.update_execute_everywhere_entry(command_key text, command TEXT, transactional BOOLEAN = true)
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    UPDATE _prom_catalog.remote_commands
    SET
        command=update_execute_everywhere_entry.command,
        transactional=update_execute_everywhere_entry.transactional
    WHERE key = command_key;
END
$func$ LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.update_execute_everywhere_entry(text, text, boolean) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.get_default_chunk_interval()
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_default_value('chunk_interval')::pg_catalog.interval;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_default_chunk_interval() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_timescale_major_version()
    RETURNS INT
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT split_part(extversion, '.', 1)::INT FROM pg_catalog.pg_extension WHERE extname='timescaledb' LIMIT 1;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_timescale_major_version() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_timescale_minor_version()
    RETURNS INT
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT split_part(extversion, '.', 2)::INT FROM pg_catalog.pg_extension WHERE extname='timescaledb' LIMIT 1;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_timescale_minor_version() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_default_retention_period()
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_default_value('retention_period')::pg_catalog.interval;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_default_retention_period() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.is_timescaledb_installed()
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT count(*) > 0 FROM pg_extension WHERE extname='timescaledb';
$func$
LANGUAGE SQL STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.is_timescaledb_installed() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.is_timescaledb_oss()
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF _prom_catalog.is_timescaledb_installed() THEN
        RETURN (SELECT current_setting('timescaledb.license') = 'apache');
    END IF;
RETURN false;
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION _prom_catalog.is_timescaledb_oss() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.is_multinode()
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT EXISTS (SELECT 1 FROM timescaledb_information.data_nodes)
$func$
LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.is_multinode() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_default_compression_setting()
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_default_value('metric_compression')::boolean;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_default_compression_setting() TO prom_reader;

--Add 1% of randomness to the interval so that chunks are not aligned so that chunks are staggered for compression jobs.
CREATE OR REPLACE FUNCTION _prom_catalog.get_staggered_chunk_interval(chunk_interval INTERVAL)
    RETURNS INTERVAL
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT chunk_interval * (1.0+((random()*0.01)-0.005));
$func$
LANGUAGE SQL;
--only used for setting chunk interval, and admin function
GRANT EXECUTE ON FUNCTION _prom_catalog.get_staggered_chunk_interval(INTERVAL) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.get_advisory_lock_id_vacuum_engine()
    RETURNS BIGINT
    SET search_path = pg_catalog, pg_temp
AS $func$
SELECT 1237719821982;
$func$
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_advisory_lock_id_vacuum_engine() TO prom_writer;
COMMENT ON FUNCTION _prom_catalog.get_advisory_lock_id_vacuum_engine()
IS 'Returns the lock id used to coordinate runs of the vacuum engine';

CREATE OR REPLACE FUNCTION _prom_catalog.lock_for_vacuum_engine()
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT pg_try_advisory_lock(_prom_catalog.get_advisory_lock_id_vacuum_engine())
$func$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.lock_for_vacuum_engine() TO prom_maintenance;
COMMENT ON FUNCTION _prom_catalog.lock_for_vacuum_engine()
IS 'Attempts to acquire an advisory lock for the vacuum engine';

CREATE OR REPLACE FUNCTION _prom_catalog.unlock_for_vacuum_engine()
    RETURNS VOID
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT pg_advisory_unlock(_prom_catalog.get_advisory_lock_id_vacuum_engine())
$func$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.unlock_for_vacuum_engine() TO prom_maintenance;
COMMENT ON FUNCTION _prom_catalog.unlock_for_vacuum_engine()
IS 'Releases the advisory lock used by the vacuum engine';

CREATE OR REPLACE FUNCTION _prom_catalog.get_advisory_lock_prefix_job()
    RETURNS INTEGER
    SET search_path = pg_catalog, pg_temp
AS $func$
SELECT 12377;
$func$
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_advisory_lock_prefix_job() TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.get_advisory_lock_prefix_maintenance()
    RETURNS INTEGER
    SET search_path = pg_catalog, pg_temp
AS $func$
   SELECT 12378;
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_advisory_lock_prefix_maintenance() TO prom_maintenance;

CREATE OR REPLACE FUNCTION _prom_catalog.lock_metric_for_maintenance(metric_id int, wait boolean = true)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    res BOOLEAN;
BEGIN
    IF NOT wait THEN
        SELECT pg_try_advisory_lock(_prom_catalog.get_advisory_lock_prefix_maintenance(), metric_id) INTO STRICT res;

        RETURN res;
    ELSE
        PERFORM pg_advisory_lock(_prom_catalog.get_advisory_lock_prefix_maintenance(), metric_id);

        RETURN TRUE;
    END IF;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.lock_metric_for_maintenance(int, boolean) TO prom_maintenance;

CREATE OR REPLACE FUNCTION _prom_catalog.unlock_metric_for_maintenance(metric_id int)
    RETURNS VOID
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
BEGIN
    PERFORM pg_advisory_unlock(_prom_catalog.get_advisory_lock_prefix_maintenance(), metric_id);
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.unlock_metric_for_maintenance(int) TO prom_maintenance;

CREATE OR REPLACE FUNCTION _prom_catalog.attach_series_partition(metric_record _prom_catalog.metric)
    RETURNS VOID
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $proc$
DECLARE
BEGIN
        EXECUTE format($$
           ALTER TABLE _prom_catalog.series ATTACH PARTITION prom_data_series.%1$I FOR VALUES IN (%2$L)
        $$, metric_record.table_name, metric_record.id);
END;
$proc$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.attach_series_partition(_prom_catalog.metric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.attach_series_partition(_prom_catalog.metric) TO prom_writer;

--Canonical lock ordering:
--metrics
--data table
--labels
--series parent
--series partition

--constraints:
--- The prom_metric view takes locks in the order: data table, series partition.


--This procedure finalizes the creation of a metric. The first part of
--metric creation happens in make_metric_table and the final part happens here.
--We split metric creation into two parts to minimize latency during insertion
--(which happens in the make_metric_table path). Especially noteworthy is that
--attaching the partition to the series table happens here because it requires
--an exclusive lock, which is a high-latency operation. The other actions this
--function does are not as critical latency-wise but are also not necessary
--to perform in order to insert data and thus are put here.
--
--Note: that a consequence of this design is that the series partition is attached
--to the series parent after in this step. Thus a metric might not be seen in some
--cross-metric queries right away. Those queries aren't common however and the delay
--is insignificant in practice.
--
--lock-order: metric table, data_table, series parent, series partition

CREATE OR REPLACE PROCEDURE _prom_catalog.finalize_metric_creation()
AS $proc$
DECLARE
    r _prom_catalog.metric;
    created boolean;
    is_view boolean;
BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;
    FOR r IN
        SELECT *
        FROM _prom_catalog.metric
        WHERE NOT creation_completed
        ORDER BY pg_catalog.random()
    LOOP
        SELECT m.creation_completed, m.is_view
        INTO created, is_view
        FROM _prom_catalog.metric m
        WHERE m.id OPERATOR(pg_catalog.=) r.id
        FOR UPDATE;

        IF created THEN
            --release row lock
            COMMIT;
            -- reset search path after transaction end
            SET LOCAL search_path = pg_catalog, pg_temp;
            CONTINUE;
        END IF;

        --do this before taking exclusive lock to minimize work after taking lock
        UPDATE _prom_catalog.metric SET creation_completed = TRUE WHERE id OPERATOR(pg_catalog.=) r.id;

        -- in case of a view, no need to attach the partition
        IF is_view THEN
            --release row lock
            COMMIT;
            -- reset search path after transaction end
            SET LOCAL search_path = pg_catalog, pg_temp;
            CONTINUE;
        END IF;

        --we will need this lock for attaching the partition so take it now
        --This may not be strictly necessary but good
        --to enforce lock ordering (parent->child) explicitly. Note:
        --creating a table as a partition takes a stronger lock (access exclusive)
        --so, attaching a partition is better
        LOCK TABLE ONLY _prom_catalog.series IN SHARE UPDATE EXCLUSIVE mode;

        PERFORM _prom_catalog.attach_series_partition(r);

        COMMIT;
        -- reset search path after transaction end
        SET LOCAL search_path = pg_catalog, pg_temp;
    END LOOP;
END;
$proc$ LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.finalize_metric_creation()
IS 'Finalizes metric creation. This procedure should be run by the connector automatically';
GRANT EXECUTE ON PROCEDURE _prom_catalog.finalize_metric_creation() TO prom_writer;

--This function is called by a trigger when a new metric is created. It
--sets up the metric just enough to insert data into it. Metric creation
--is completed in finalize_metric_creation() above. See the comments
--on that function for the reasoning for this split design.
--
--Note: latency-sensitive function. Should only contain just enough logic
--to support inserts for the metric.
--lock-order: data table, labels, series partition.
CREATE OR REPLACE FUNCTION _prom_catalog.make_metric_table()
    RETURNS trigger
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
  label_id INT;
BEGIN
    -- if a database restore is in progress do not create metric tables as they will be created as a part of the restore
    IF _prom_catalog.is_restore_in_progress() THEN
        RETURN NEW;
    END IF;

    -- Note: if the inserted metric is a view, nothing to do.
    IF NEW.is_view THEN
        RETURN NEW;
    END IF;

    --autovacuum notes: we need to vacuum here for the visibility map optimization
    --but, we don't want to freeze anything since these tables will be truncated upon
    --compression anyway (so keep freeze settings to the default).
    --Make the vacuum less aggressive here by upping the threshold and scale factors.
    IF current_setting('server_version_num')::integer >= 130000 THEN
        EXECUTE format('CREATE TABLE %I.%I(time TIMESTAMPTZ NOT NULL, value DOUBLE PRECISION NOT NULL, series_id BIGINT NOT NULL) WITH
                        (
                            autovacuum_vacuum_insert_threshold=50000,
                            autovacuum_vacuum_insert_scale_factor=2.0,
                            autovacuum_analyze_threshold = 50000,
                            autovacuum_analyze_scale_factor = 0.5
                        )',
        NEW.table_schema, NEW.table_name);
    ELSE
        --pg12 doesn't have autovacuum_vacuum_insert_threshold
        EXECUTE format('CREATE TABLE %I.%I(time TIMESTAMPTZ NOT NULL, value DOUBLE PRECISION NOT NULL, series_id BIGINT NOT NULL) WITH
                        (
                            autovacuum_analyze_threshold = 50000,
                            autovacuum_analyze_scale_factor=0.5
                        )',
        NEW.table_schema, NEW.table_name);
    END IF;
    EXECUTE format('GRANT SELECT ON TABLE %I.%I TO prom_reader', NEW.table_schema, NEW.table_name);
    EXECUTE format('GRANT SELECT, INSERT ON TABLE %I.%I TO prom_writer', NEW.table_schema, NEW.table_name);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I.%I TO prom_modifier', NEW.table_schema, NEW.table_name);
    EXECUTE format('CREATE UNIQUE INDEX data_series_id_time_%s ON %I.%I (series_id, time) INCLUDE (value)',
                    NEW.id, NEW.table_schema, NEW.table_name);

    --dynamically created tables are owned by our highest-privileged role, prom_admin
    --these cannot be made part of the extension since we cannot make them config
    --tables outside of extension upgrade/install scripts. They cannot be superuser
    --owned without being part extension since that would prevent dump/restore from
    --working on any environment without SU privileges (such as cloud).
    EXECUTE format('ALTER TABLE %I.%I OWNER TO prom_admin', NEW.table_schema, NEW.table_name);

    IF _prom_catalog.is_timescaledb_installed() THEN
        IF _prom_catalog.is_multinode() THEN
            --Note: we intentionally do not partition by series_id here. The assumption is
            --that we'll have more "heavy metrics" than nodes and thus partitioning /individual/
            --metrics won't gain us much for inserts and would be detrimental for many queries.
            PERFORM public.create_distributed_hypertable(
                format('%I.%I', NEW.table_schema, NEW.table_name),
                'time',
                chunk_time_interval=>_prom_catalog.get_staggered_chunk_interval(_prom_catalog.get_default_chunk_interval()),
                create_default_indexes=>false
            );
        ELSE
            PERFORM public.create_hypertable(format('%I.%I', NEW.table_schema, NEW.table_name), 'time',
            chunk_time_interval=>_prom_catalog.get_staggered_chunk_interval(_prom_catalog.get_default_chunk_interval()),
                             create_default_indexes=>false);
        END IF;
    END IF;

    --Do not move this into the finalize step, because it's cheap to do while the table is empty
    --but takes a heavyweight blocking lock otherwise.
    IF  _prom_catalog.is_timescaledb_installed()
        AND _prom_catalog.get_default_compression_setting() THEN
        PERFORM prom_api.set_compression_on_metric_table(NEW.table_name, TRUE);
    END IF;
    EXECUTE format('GRANT ALL PRIVILEGES ON TABLE %I.%I TO prom_admin', NEW.table_schema, NEW.table_name);

    SELECT _prom_catalog.get_or_create_label_id('__name__', NEW.metric_name)
    INTO STRICT label_id;
    --note that because labels[1] is unique across partitions and UNIQUE(labels) inside partition, labels are guaranteed globally unique
    EXECUTE format($$
        CREATE TABLE prom_data_series.%1$I (
            id bigint NOT NULL,
            metric_id int NOT NULL,
            labels prom_api.label_array NOT NULL,
            delete_epoch BIGINT NULL DEFAULT NULL,
            CHECK(labels[1] = %2$L AND labels[1] IS NOT NULL),
            CHECK(metric_id = %3$L),
            CONSTRAINT series_labels_id_%3$s UNIQUE(labels) INCLUDE (id),
            CONSTRAINT series_pkey_%3$s PRIMARY KEY(id)
        ) WITH (autovacuum_vacuum_threshold = 100, autovacuum_analyze_threshold = 100)
    $$, NEW.table_name, label_id, NEW.id);
    EXECUTE format('GRANT SELECT ON TABLE prom_data_series.%I TO prom_reader', NEW.table_name);
    EXECUTE format('GRANT SELECT, INSERT ON TABLE prom_data_series.%I TO prom_writer', NEW.table_name);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE prom_data_series.%I TO prom_modifier', NEW.table_name);

    --these indexes are logically on all series tables but they cannot be defined on the parent due to
    --dump/restore issues.
    EXECUTE format('CREATE INDEX series_labels_%s ON prom_data_series.%I USING GIN (labels)', NEW.id, NEW.table_name);
    EXECUTE format('CREATE INDEX series_delete_epoch_id_%s ON prom_data_series.%I (delete_epoch, id) WHERE delete_epoch IS NOT NULL', NEW.id, NEW.table_name);

    EXECUTE format('ALTER TABLE prom_data_series.%1$I OWNER TO prom_admin', NEW.table_name);
    EXECUTE format('GRANT ALL PRIVILEGES ON TABLE prom_data_series.%I TO prom_admin', NEW.table_name);
    RETURN NEW;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.make_metric_table() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.make_metric_table() TO prom_writer;

DROP TRIGGER IF EXISTS make_metric_table_trigger ON _prom_catalog.metric CASCADE;
CREATE TRIGGER make_metric_table_trigger
    AFTER INSERT ON _prom_catalog.metric
    FOR EACH ROW
    EXECUTE PROCEDURE _prom_catalog.make_metric_table();


------------------------
-- Internal functions --
------------------------

-- Return a table name built from a full_name and a suffix.
-- The full name is truncated so that the suffix could fit in full.
-- name size will always be exactly 62 chars.
CREATE OR REPLACE FUNCTION _prom_catalog.pg_name_with_suffix(full_name text, suffix text)
    RETURNS name
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT (substring(full_name for 62-(char_length(suffix)+1)) || '_' || suffix)::name
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.pg_name_with_suffix(text, text) TO prom_reader;

-- Return a new unique name from a name and id.
-- This tries to use the full_name in full. But if the
-- full name doesn't fit, generates a new unique name.
-- Note that there cannot be a collision betweeen a user
-- defined name and a name with a suffix because user
-- defined names of length 62 always get a suffix and
-- conversely, all names with a suffix are length 62.

-- We use a max name length of 62 not 63 because table creation creates an
-- array type named `_tablename`. We need to ensure that this name is
-- unique as well, so have to reserve a space for the underscore.
CREATE OR REPLACE FUNCTION _prom_catalog.pg_name_unique(full_name_arg text, suffix text)
    RETURNS name
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT CASE
        WHEN char_length(full_name_arg) < 62 THEN
            full_name_arg::name
        ELSE
            _prom_catalog.pg_name_with_suffix(
                full_name_arg, suffix
            )
        END
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.pg_name_unique(text, text) TO prom_reader;

--Creates a new table for a given metric name.
--This uses up some sequences so should only be called
--If the table does not yet exist.
--The function inserts into the metric catalog table,
--  which causes the make_metric_table trigger to fire,
--  which actually creates the table
-- locks: metric, make_metric_table[data table, labels, series partition]
CREATE OR REPLACE FUNCTION _prom_catalog.create_metric_table(
        metric_name_arg text, OUT id int, OUT table_name name)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
  new_id int;
  new_table_name name;
BEGIN
new_id = nextval(pg_get_serial_sequence('_prom_catalog.metric','id'))::int;
new_table_name = _prom_catalog.pg_name_unique(metric_name_arg, new_id::text);
LOOP
    INSERT INTO _prom_catalog.metric (id, metric_name, table_schema, table_name, series_table)
        SELECT  new_id,
                metric_name_arg,
                'prom_data',
                new_table_name,
                new_table_name
    ON CONFLICT DO NOTHING
    RETURNING _prom_catalog.metric.id, _prom_catalog.metric.table_name
    INTO id, table_name;
    -- under high concurrency the insert may not return anything, so try a select and loop
    -- https://stackoverflow.com/a/15950324
    EXIT WHEN FOUND;

    SELECT m.id, m.table_name
    INTO id, table_name
    FROM _prom_catalog.metric m
    WHERE metric_name = metric_name_arg;

    EXIT WHEN FOUND;
END LOOP;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.create_metric_table(text) TO prom_writer;

--Creates a new label_key row for a given key.
--This uses up some sequences so should only be called
--If the table does not yet exist.
CREATE OR REPLACE FUNCTION _prom_catalog.create_label_key(
        new_key TEXT, OUT id INT, OUT value_column_name NAME, OUT id_column_name NAME
)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
  new_id int;
BEGIN
new_id = nextval(pg_get_serial_sequence('_prom_catalog.label_key','id'))::int;
LOOP
    INSERT INTO _prom_catalog.label_key (id, key, value_column_name, id_column_name)
        SELECT  new_id,
                new_key,
                _prom_catalog.pg_name_unique(new_key, new_id::text),
                _prom_catalog.pg_name_unique(new_key || '_id', format('%s_id', new_id))
    ON CONFLICT DO NOTHING
    RETURNING _prom_catalog.label_key.id, _prom_catalog.label_key.value_column_name, _prom_catalog.label_key.id_column_name
    INTO id, value_column_name, id_column_name;
    -- under high concurrency the insert may not return anything, so try a select and loop
    -- https://stackoverflow.com/a/15950324
    EXIT WHEN FOUND;

    SELECT lk.id, lk.value_column_name, lk.id_column_name
    INTO id, value_column_name, id_column_name
    FROM _prom_catalog.label_key lk
    WHERE key = new_key;

    EXIT WHEN FOUND;
END LOOP;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.create_label_key(TEXT) TO prom_writer;

--Get a label key row if one doesn't yet exist.
CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_label_key(
        key TEXT, OUT id INT, OUT value_column_name NAME, OUT id_column_name NAME)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
   SELECT id, value_column_name, id_column_name
   FROM _prom_catalog.label_key lk
   WHERE lk.key = get_or_create_label_key.key
   UNION ALL
   SELECT *
   FROM _prom_catalog.create_label_key(get_or_create_label_key.key)
   LIMIT 1
$func$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_label_key(TEXT) to prom_writer;

-- Get a new label array position for a label key. For any metric,
-- we want the positions to be as compact as possible.
-- This uses some pretty heavy locks so use sparingly.
-- locks: label_key_position, data table, series partition (in view creation),
CREATE OR REPLACE FUNCTION _prom_catalog.get_new_pos_for_key(
        metric_name text, metric_table text, key_name_array text[], is_for_exemplar boolean)
    RETURNS int[]
    --security definer needed to lock the series table
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    position int;
    position_array int[];
    position_array_idx int;
    count_new int;
    key_name text;
    next_position int;
    max_position int;
    position_table_name text;
BEGIN
    If is_for_exemplar THEN
        position_table_name := 'exemplar_label_key_position';
    ELSE
        position_table_name := 'label_key_position';
    END IF;

    --Use double check locking here
    --fist optimistic check:
    position_array := NULL;
    EXECUTE FORMAT('SELECT array_agg(p.pos ORDER BY k.ord)
        FROM
            unnest($1) WITH ORDINALITY as k(key, ord)
        INNER JOIN
            _prom_catalog.%I p ON
        (
            p.metric_name = $2
            AND p.key = k.key
        )', position_table_name) USING key_name_array, metric_name
    INTO position_array;

    -- Return the array if the length is same, as the received key_name_array does not contain any new keys.
    IF array_length(key_name_array, 1) = array_length(position_array, 1) THEN
        RETURN position_array;
    END IF;

    -- Lock tables for exclusiveness.
    IF NOT is_for_exemplar THEN
        --lock as for ALTER TABLE because we are in effect changing the schema here
        --also makes sure the next_position below is correct in terms of concurrency
        EXECUTE format('LOCK TABLE prom_data_series.%I IN SHARE UPDATE EXCLUSIVE MODE', metric_table);
    ELSE
        LOCK TABLE _prom_catalog.exemplar_label_key_position IN ACCESS EXCLUSIVE MODE;
    END IF;

    max_position := NULL;
    EXECUTE FORMAT('SELECT max(pos) + 1
        FROM _prom_catalog.%I
    WHERE metric_name = $1', position_table_name) USING get_new_pos_for_key.metric_name
    INTO max_position;

    IF max_position IS NULL THEN
        IF is_for_exemplar THEN
            max_position := 1;
        ELSE
            -- Specific to label_key_position table only.
            max_position := 2; -- element 1 reserved for __name__
        END IF;
    END IF;

    position_array := array[]::int[];
    position_array_idx := 1;
    count_new := 0;
    FOREACH key_name IN ARRAY key_name_array LOOP
        --second check after lock
        position := NULL;
        EXECUTE FORMAT('SELECT pos FROM _prom_catalog.%I lp
        WHERE
            lp.metric_name = $1
        AND
            lp.key = $2', position_table_name) USING metric_name, key_name
        INTO position;

        IF position IS NOT NULL THEN
            position_array[position_array_idx] := position;
            position_array_idx := position_array_idx + 1;
            CONTINUE;
        END IF;
        -- key_name does not exists in the position table.
        count_new := count_new + 1;
        IF (NOT is_for_exemplar) AND (key_name = '__name__') THEN
            next_position := 1; -- 1-indexed arrays, __name__ as first element
        ELSE
            next_position := max_position;
            max_position := max_position + 1;
        END IF;

        IF NOT is_for_exemplar THEN
            PERFORM _prom_catalog.get_or_create_label_key(key_name);
        END IF;

        position := NULL;
        EXECUTE FORMAT('INSERT INTO _prom_catalog.%I
        VALUES ($1, $2, $3)
            ON CONFLICT DO NOTHING
        RETURNING pos', position_table_name) USING metric_name, key_name, next_position
        INTO position;

        IF position IS NULL THEN
            RAISE 'Could not find a new position. (is_for_exemplar=%)', is_for_exemplar;
        END IF;
        position_array[position_array_idx] := position;
        position_array_idx := position_array_idx + 1;
    END LOOP;

    IF NOT is_for_exemplar AND count_new > 0 THEN
        --note these functions are expensive in practice so they
        --must be run once across a collection of keys
        PERFORM _prom_catalog.create_series_view(metric_name);
        PERFORM _prom_catalog.create_metric_view(metric_name);
    END IF;

    RETURN position_array;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.get_new_pos_for_key(text, text, text[], boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_new_pos_for_key(text, text, text[], boolean) TO prom_reader; -- For exemplars querying.
GRANT EXECUTE ON FUNCTION _prom_catalog.get_new_pos_for_key(text, text, text[], boolean) TO prom_writer;

--should only be called after a check that that the label doesn't exist
CREATE OR REPLACE FUNCTION _prom_catalog.get_new_label_id(key_name text, value_name text, OUT id INT)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
LOOP
    INSERT INTO
        _prom_catalog.label(key, value)
    VALUES
        (key_name,value_name)
    ON CONFLICT DO NOTHING
    RETURNING _prom_catalog.label.id
    INTO id;

    EXIT WHEN FOUND;

    SELECT
        l.id
    INTO id
    FROM _prom_catalog.label l
    WHERE
        key = key_name AND
        value = value_name;

    EXIT WHEN FOUND;
END LOOP;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_new_label_id(text, text) to prom_writer;

--wrapper around jsonb_each_text to give a better row_estimate
--for labels (10 not 100)
CREATE OR REPLACE FUNCTION _prom_catalog.label_jsonb_each_text(js jsonb, OUT key text, OUT value text)
    RETURNS SETOF record
    LANGUAGE INTERNAL
IMMUTABLE PARALLEL SAFE STRICT ROWS 10
AS $function$jsonb_each_text$function$;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_jsonb_each_text(jsonb) to prom_reader;

--wrapper around unnest to give better row estimate (10 not 100)
CREATE OR REPLACE FUNCTION _prom_catalog.label_unnest(label_array anyarray)
    RETURNS SETOF anyelement
    LANGUAGE INTERNAL
IMMUTABLE PARALLEL SAFE STRICT ROWS 10
AS $function$array_unnest$function$;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_unnest(anyarray) to prom_reader;

-- safe_approximate_row_count returns the approximate row count of a hypertable if timescaledb is installed
-- else returns the approximate row count in the normal table. This prevents errors in approximate count calculation
-- if timescaledb is not installed, which is the case in plain postgres support.
CREATE OR REPLACE FUNCTION _prom_catalog.safe_approximate_row_count(table_name_input REGCLASS)
    RETURNS BIGINT
    LANGUAGE PLPGSQL
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    IF _prom_catalog.get_timescale_major_version() >= 2 THEN
        RETURN (SELECT * FROM public.approximate_row_count(table_name_input));
    ELSE
        IF _prom_catalog.is_timescaledb_installed() THEN
            IF (SELECT count(*) > 0
                FROM _timescaledb_catalog.hypertable
                WHERE format('%I.%I', schema_name, table_name)::regclass=table_name_input)
            THEN
                RETURN (SELECT row_estimate FROM hypertable_approximate_row_count(table_name_input));
            END IF;
        END IF;
        RETURN (SELECT reltuples::BIGINT FROM pg_class WHERE oid=table_name_input);
    END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION _prom_catalog.safe_approximate_row_count(regclass) to prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.delete_series_catalog_row(
    metric_table text,
    series_ids bigint[]
)
    RETURNS VOID
    SET search_path = pg_catalog, pg_temp
AS
$$
BEGIN
    EXECUTE FORMAT(
        'UPDATE prom_data_series.%1$I SET delete_epoch = current_epoch+1 FROM _prom_catalog.ids_epoch WHERE delete_epoch IS NULL AND id = ANY($1)',
        metric_table
    ) USING series_ids;
    RETURN;
END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.delete_series_catalog_row(text, bigint[]) to prom_modifier;

---------------------------------------------------
------------------- Public APIs -------------------
---------------------------------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.get_metric_table_name_if_exists(schema text, metric_name text)
    RETURNS TABLE (id int, table_name name, table_schema name, series_table name, is_view boolean)
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    rows_found bigint;
BEGIN
    IF get_metric_table_name_if_exists.schema != '' AND get_metric_table_name_if_exists.schema IS NOT NULL THEN
        RETURN QUERY SELECT m.id, m.table_name::name, m.table_schema::name, m.series_table::name, m.is_view
        FROM _prom_catalog.metric m
        WHERE m.table_schema = get_metric_table_name_if_exists.schema
        AND m.metric_name = get_metric_table_name_if_exists.metric_name;
        RETURN;
    END IF;

    RETURN QUERY SELECT m.id, m.table_name::name, m.table_schema::name, m.series_table::name, m.is_view
    FROM _prom_catalog.metric m
    WHERE m.table_schema = 'prom_data'
    AND m.metric_name = get_metric_table_name_if_exists.metric_name;

    IF FOUND THEN
        RETURN;
    END IF;

    SELECT count(*)
    INTO rows_found
    FROM _prom_catalog.metric m
    WHERE m.metric_name = get_metric_table_name_if_exists.metric_name;

    IF rows_found <= 1 THEN
        RETURN QUERY SELECT m.id, m.table_name::name, m.table_schema::name, m.series_table::name, m.is_view
        FROM _prom_catalog.metric m
        WHERE m.metric_name = get_metric_table_name_if_exists.metric_name;
        RETURN;
    END IF;

    RAISE EXCEPTION 'found multiple metrics with same name in different schemas, please specify exact schema name';
END
$func$
LANGUAGE PLPGSQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_metric_table_name_if_exists(text, text) to prom_reader;

-- Public function to get the name of the table for a given metric
-- This will create the metric table if it does not yet exist.
CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_metric_table_name(
        metric_name text, OUT id int, OUT table_name name, OUT possibly_new BOOLEAN)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
   SELECT id, table_name::name, false
   FROM _prom_catalog.metric m
   WHERE m.metric_name = get_or_create_metric_table_name.metric_name
   AND m.table_schema = 'prom_data'
   UNION ALL
   SELECT *, true
   FROM _prom_catalog.create_metric_table(get_or_create_metric_table_name.metric_name)
   LIMIT 1
$func$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_metric_table_name(text) to prom_writer;

--public function to get the array position for a label key
CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_label_key_pos(
        metric_name text, key text)
    RETURNS INT
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
    --only executes the more expensive PLPGSQL function if the label doesn't exist
    SELECT
        pos
    FROM
        _prom_catalog.label_key_position lkp
    WHERE
        lkp.metric_name = get_or_create_label_key_pos.metric_name
        AND lkp.key = get_or_create_label_key_pos.key
    UNION ALL
    SELECT
        (_prom_catalog.get_new_pos_for_key(get_or_create_label_key_pos.metric_name, m.table_name, array[get_or_create_label_key_pos.key], false))[1]
    FROM
        _prom_catalog.get_or_create_metric_table_name(get_or_create_label_key_pos.metric_name) m
    LIMIT 1
$$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_label_key_pos(text, text) to prom_writer;

-- label_cardinality returns the cardinality of a label_pair id in the series table.
-- In simple terms, it means the number of times a label_pair/label_matcher is used
-- across all the series.
CREATE OR REPLACE FUNCTION prom_api.label_cardinality(label_id INT)
    RETURNS INT
    LANGUAGE SQL
    SET search_path = pg_catalog, pg_temp
AS
$$
    SELECT count(*)::INT FROM _prom_catalog.series s WHERE s.labels @> array[label_id];
$$ STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION prom_api.label_cardinality(int) to prom_reader;

--public function to get the array position for a label key if it exists
--useful in case users want to group by a specific label key
CREATE OR REPLACE FUNCTION prom_api.label_key_position(
        metric_name text, key text)
    RETURNS INT
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT
        pos
    FROM
        _prom_catalog.label_key_position lkp
    WHERE
        lkp.metric_name = label_key_position.metric_name
        AND lkp.key = label_key_position.key
    LIMIT 1
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION prom_api.label_key_position(text, text) to prom_reader;

-- drop_metric deletes a metric and related series hypertable from the database along with the related series, views and unreferenced labels.
CREATE OR REPLACE FUNCTION prom_api.drop_metric(metric_name_to_be_dropped text) RETURNS VOID
    SET search_path = pg_catalog, pg_temp
AS
$$
    DECLARE
        hypertable_name TEXT;
        deletable_metric_id INTEGER;
    BEGIN
        IF (SELECT NOT pg_try_advisory_xact_lock(5585198506344173278)) THEN
            RAISE NOTICE 'drop_metric can run only when no Promscale connectors are running. Please shutdown the Promscale connectors';
            PERFORM pg_advisory_xact_lock(5585198506344173278);
        END IF;
        SELECT table_name, id INTO hypertable_name, deletable_metric_id FROM _prom_catalog.metric WHERE metric_name=metric_name_to_be_dropped;
        IF NOT FOUND THEN
          RAISE '% is not a metric. unable to drop it.', metric_name_to_be_dropped;
        END IF;
        RAISE NOTICE 'deleting "%" metric with metric_id as "%" and table_name as "%"', metric_name_to_be_dropped, deletable_metric_id, hypertable_name;
        EXECUTE FORMAT('DROP VIEW IF EXISTS prom_series.%1$I;', hypertable_name);
        EXECUTE FORMAT('DROP VIEW IF EXISTS prom_metric.%1$I;', hypertable_name);
        EXECUTE FORMAT('DROP TABLE IF EXISTS prom_data_series.%1$I;', hypertable_name);
        EXECUTE FORMAT('DROP TABLE IF EXISTS prom_data.%1$I;', hypertable_name);
        DELETE FROM _prom_catalog.metric WHERE id=deletable_metric_id;
        -- clean up unreferenced labels, label_keys and its position.
        DELETE FROM _prom_catalog.label_key_position WHERE metric_name=metric_name_to_be_dropped;
        DELETE FROM _prom_catalog.label_key WHERE key NOT IN (select key from _prom_catalog.label_key_position);
    END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION prom_api.drop_metric(text) to prom_admin;

--Get the label_id for a key, value pair
-- no need for a get function only as users will not be using ids directly
CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_label_id(
        key_name text, value_name text)
    RETURNS INT
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
    --first select to prevent sequence from being used up
    --unnecessarily
    SELECT
        id
    FROM _prom_catalog.label
    WHERE
        key = key_name AND
        value = value_name
    UNION ALL
    SELECT
        _prom_catalog.get_new_label_id(key_name, value_name)
    LIMIT 1
$$
LANGUAGE SQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_label_id(text, text) to prom_writer;

--This generates a position based array from the jsonb
--0s represent keys that are not set (we don't use NULL
--since intarray does not support it).
--This is not super performance critical since this
--is only used on the insert client and is cached there.
--Read queries can use the eq function or others with the jsonb to find equality
CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_label_array(js jsonb)
    RETURNS prom_api.label_array
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
    WITH idx_val AS (
        SELECT
            -- only call the functions to create new key positions
            -- and label ids if they don't exist (for performance reasons)
            coalesce(lkp.pos,
              _prom_catalog.get_or_create_label_key_pos(js->>'__name__', e.key)) idx,
            coalesce(l.id,
              _prom_catalog.get_or_create_label_id(e.key, e.value)) val
        FROM _prom_catalog.label_jsonb_each_text(js) e
             LEFT JOIN _prom_catalog.label l
               ON (l.key = e.key AND l.value = e.value)
            LEFT JOIN _prom_catalog.label_key_position lkp
               ON
               (
                  lkp.metric_name = js->>'__name__' AND
                  lkp.key = e.key
               )
        --needs to order by key to prevent deadlocks if get_or_create_label_id is creating labels
        ORDER BY l.key
    )
    SELECT ARRAY(
        SELECT coalesce(idx_val.val, 0)
        FROM
            generate_series(
                    1,
                    (SELECT max(idx) FROM idx_val)
            ) g
            LEFT JOIN idx_val ON (idx_val.idx = g)
    )::prom_api.label_array
$$
LANGUAGE SQL;
COMMENT ON FUNCTION _prom_catalog.get_or_create_label_array(jsonb)
IS 'converts a jsonb to a label array';
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_label_array(jsonb) TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_label_array(metric_name TEXT, label_keys text[], label_values text[])
    RETURNS prom_api.label_array
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
    WITH idx_val AS (
        SELECT
            -- only call the functions to create new key positions
            -- and label ids if they don't exist (for performance reasons)
            coalesce(lkp.pos,
              _prom_catalog.get_or_create_label_key_pos(get_or_create_label_array.metric_name, kv.key)) idx,
            coalesce(l.id,
              _prom_catalog.get_or_create_label_id(kv.key, kv.value)) val
        FROM ROWS FROM(unnest(label_keys), UNNEST(label_values)) AS kv(key, value)
            LEFT JOIN _prom_catalog.label l
               ON (l.key = kv.key AND l.value = kv.value)
            LEFT JOIN _prom_catalog.label_key_position lkp
               ON
               (
                  lkp.metric_name = get_or_create_label_array.metric_name AND
                  lkp.key = kv.key
               )
        ORDER BY kv.key
    )
    SELECT ARRAY(
        SELECT coalesce(idx_val.val, 0)
        FROM
            generate_series(
                    1,
                    (SELECT max(idx) FROM idx_val)
            ) g
            LEFT JOIN idx_val ON (idx_val.idx = g)
    )::prom_api.label_array
$$
LANGUAGE SQL;
COMMENT ON FUNCTION _prom_catalog.get_or_create_label_array(text, text[], text[])
IS 'converts a metric name, array of keys, and array of values to a label array';
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_label_array(TEXT, text[], text[]) TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_label_ids(metric_name TEXT, metric_table TEXT, label_keys text[], label_values text[])
    RETURNS TABLE(pos int[], id int[], label_key text[], label_value text[])
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
        WITH cte as (
        SELECT
            -- only call the functions to create new key positions
            -- and label ids if they don't exist (for performance reasons)
            lkp.pos as known_pos,
            coalesce(l.id, _prom_catalog.get_or_create_label_id(kv.key, kv.value)) label_id,
            kv.key key_str,
            kv.value val_str
        FROM ROWS FROM(unnest(label_keys), UNNEST(label_values)) AS kv(key, value)
            LEFT JOIN _prom_catalog.label l
               ON (l.key = kv.key AND l.value = kv.value)
            LEFT JOIN _prom_catalog.label_key_position lkp ON
            (
                    lkp.metric_name = get_or_create_label_ids.metric_name AND
                    lkp.key = kv.key
            )
        ORDER BY kv.key, kv.value
        )
        SELECT
           case when count(*) = count(known_pos) Then
              array_agg(known_pos)
           else
              _prom_catalog.get_new_pos_for_key(get_or_create_label_ids.metric_name, get_or_create_label_ids.metric_table, array_agg(key_str), false)
           end as poss,
           array_agg(label_id) as label_ids,
           array_agg(key_str) as keys,
           array_agg(val_str) as vals
        FROM cte
$$
LANGUAGE SQL;
COMMENT ON FUNCTION _prom_catalog.get_or_create_label_ids(text, text, text[], text[])
IS 'converts a metric name, array of keys, and array of values to a list of label ids';
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_label_ids(TEXT, TEXT, text[], text[]) TO prom_writer;


-- Returns ids, keys and values for a label_array
-- the order may not be the same as the original labels
-- This function needs to be optimized for performance
CREATE OR REPLACE FUNCTION prom_api.labels_info(INOUT labels INT[], OUT keys text[], OUT vals text[])
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT
        array_agg(l.id), array_agg(l.key), array_agg(l.value)
    FROM
      _prom_catalog.label_unnest(labels) label_id
      INNER JOIN _prom_catalog.label l ON (l.id = label_id)
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.labels_info(INT[])
IS 'converts an array of label ids to three arrays: one for ids, one for keys and another for values';
GRANT EXECUTE ON FUNCTION prom_api.labels_info(INT[]) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.key_value_array(labels prom_api.label_array, OUT keys text[], OUT vals text[])
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT keys, vals FROM prom_api.labels_info(labels)
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.key_value_array(prom_api.label_array)
IS 'converts a labels array to two arrays: one for keys and another for values';
GRANT EXECUTE ON FUNCTION prom_api.key_value_array(prom_api.label_array) TO prom_reader;

--Returns the jsonb for a series defined by a label_array
CREATE OR REPLACE FUNCTION prom_api.jsonb(labels prom_api.label_array)
    RETURNS jsonb
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT
        jsonb_object(keys, vals)
    FROM
      prom_api.key_value_array(labels)
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.jsonb(labels prom_api.label_array)
IS 'converts a labels array to a JSONB object';
GRANT EXECUTE ON FUNCTION prom_api.jsonb(prom_api.label_array) TO prom_reader;

--Returns the label_array given a series_id
CREATE OR REPLACE FUNCTION prom_api.labels(series_id BIGINT)
    RETURNS prom_api.label_array
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT
        labels
    FROM
        _prom_catalog.series
    WHERE id = series_id
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.labels(series_id BIGINT)
IS 'fetches labels array for the given series id';
GRANT EXECUTE ON FUNCTION prom_api.labels(series_id BIGINT) TO prom_reader;

--Do not call before checking that the series does not yet exist
CREATE OR REPLACE FUNCTION _prom_catalog.create_series(
        metric_id int,
        metric_table_name TEXT,
        label_array prom_api.label_array,
        OUT series_id BIGINT)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
   new_series_id bigint;
BEGIN
  new_series_id = nextval('_prom_catalog.series_id');
LOOP
    EXECUTE format ($$
        INSERT INTO prom_data_series.%I(id, metric_id, labels)
        SELECT $1, $2, $3
        ON CONFLICT DO NOTHING
        RETURNING id
    $$, metric_table_name)
    INTO series_id
    USING new_series_id, metric_id, label_array;

    EXIT WHEN series_id is not null;

    EXECUTE format($$
        SELECT id
        FROM prom_data_series.%I
        WHERE labels = $1
    $$, metric_table_name)
    INTO series_id
    USING label_array;

    EXIT WHEN series_id is not null;
END LOOP;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.create_series(int, text, prom_api.label_array) TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.resurrect_series_ids(metric_table text, series_id bigint)
    RETURNS VOID
    --security definer to add jobs as the logged-in user
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    EXECUTE FORMAT($query$
        UPDATE prom_data_series.%1$I
        SET delete_epoch = NULL
        WHERE id = $1
    $query$, metric_table) using series_id;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.resurrect_series_ids(text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.resurrect_series_ids(text, bigint) TO prom_writer;

-- There shouldn't be a need to have a read only version of this as we'll use
-- the eq or other matcher functions to find series ids like this. However,
-- there are possible use cases that need the series id directly for performance
-- that we might want to see if we need to support, in which case a
-- read only version might be useful in future.
CREATE OR REPLACE  FUNCTION _prom_catalog.get_or_create_series_id(label jsonb)
    RETURNS BIGINT
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  series_id bigint;
  table_name name;
  metric_id int;
BEGIN
   --See get_or_create_series_id_for_kv_array for notes about locking
   SELECT mtn.id, mtn.table_name FROM _prom_catalog.get_or_create_metric_table_name(label->>'__name__') mtn
   INTO metric_id, table_name;

   LOCK TABLE ONLY _prom_catalog.series in ACCESS SHARE mode;

   EXECUTE format($query$
    WITH cte AS (
        SELECT _prom_catalog.get_or_create_label_array($1)
    ), existing AS (
        SELECT
            id,
            CASE WHEN delete_epoch IS NOT NULL THEN
                _prom_catalog.resurrect_series_ids(%1$L, id)
            END
        FROM prom_data_series.%1$I as series
        WHERE labels = (SELECT * FROM cte)
    )
    SELECT id FROM existing
    UNION ALL
    SELECT _prom_catalog.create_series(%2$L, %1$L, (SELECT * FROM cte))
    LIMIT 1
   $query$, table_name, metric_id)
   USING label
   INTO series_id;

   RETURN series_id;
END
$$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION _prom_catalog.get_or_create_series_id(jsonb)
IS 'returns the series id that exactly matches a JSONB of labels';
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_series_id(jsonb) TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_series_id_for_kv_array(metric_name TEXT, label_keys text[], label_values text[], OUT table_name NAME, OUT series_id BIGINT)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
  metric_id int;
BEGIN
   --need to make sure the series partition exists
   SELECT mtn.id, mtn.table_name FROM _prom_catalog.get_or_create_metric_table_name(metric_name) mtn
   INTO metric_id, table_name;

   -- the data table could be locked during label key creation
   -- and must be locked before the series parent according to lock ordering
   EXECUTE format($query$
        LOCK TABLE ONLY prom_data.%1$I IN ACCESS SHARE MODE
    $query$, table_name);

   EXECUTE format($query$
    WITH cte AS (
        SELECT _prom_catalog.get_or_create_label_array($1, $2, $3)
    ), existing AS (
        SELECT
            id,
            CASE WHEN delete_epoch IS NOT NULL THEN
                _prom_catalog.resurrect_series_ids(%1$L, id)
            END
        FROM prom_data_series.%1$I as series
        WHERE labels = (SELECT * FROM cte)
    )
    SELECT id FROM existing
    UNION ALL
    SELECT _prom_catalog.create_series(%2$L, %1$L, (SELECT * FROM cte))
    LIMIT 1
   $query$, table_name, metric_id)
   USING metric_name, label_keys, label_values
   INTO series_id;

   RETURN;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_series_id_for_kv_array(TEXT, text[], text[]) TO prom_writer;


CREATE OR REPLACE FUNCTION _prom_catalog.get_or_create_series_id_for_label_array(metric_id INT, table_name TEXT, larray prom_api.label_array, OUT series_id BIGINT)
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
   EXECUTE format($query$
    WITH existing AS (
        SELECT
            id,
            CASE WHEN delete_epoch IS NOT NULL THEN
                _prom_catalog.resurrect_series_ids(%1$L, id)
            END
        FROM prom_data_series.%1$I as series
        WHERE labels = $1
    )
    SELECT id FROM existing
    UNION ALL
    SELECT _prom_catalog.create_series(%2$L, %1$L, $1)
    LIMIT 1
   $query$, table_name, metric_id)
   USING larray
   INTO series_id;

   RETURN;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_or_create_series_id_for_label_array(INT, TEXT, prom_api.label_array) TO prom_writer;

--
-- Parameter manipulation functions
--

CREATE OR REPLACE FUNCTION _prom_catalog.set_chunk_interval_on_metric_table(metric_name TEXT, new_interval INTERVAL)
    RETURNS void
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RAISE EXCEPTION 'cannot set chunk time interval without timescaledb installed';
    END IF;
    --set interval while adding 1% of randomness to the interval so that chunks are not aligned so that
    --chunks are staggered for compression jobs.
    EXECUTE public.set_chunk_time_interval(
        format('prom_data.%I',(SELECT table_name FROM _prom_catalog.get_or_create_metric_table_name(metric_name)))::regclass,
         _prom_catalog.get_staggered_chunk_interval(new_interval));
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.set_chunk_interval_on_metric_table(TEXT, INTERVAL) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.set_chunk_interval_on_metric_table(TEXT, INTERVAL) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_default_chunk_interval(chunk_interval INTERVAL)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.set_default_value('chunk_interval', chunk_interval::pg_catalog.text);

    SELECT _prom_catalog.set_chunk_interval_on_metric_table(metric_name, chunk_interval)
    FROM _prom_catalog.metric
    WHERE default_chunk_interval;

    SELECT true;
$$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.set_default_chunk_interval(INTERVAL)
IS 'set the chunk interval for any metrics (existing and new) without an explicit override';
GRANT EXECUTE ON FUNCTION prom_api.set_default_chunk_interval(INTERVAL) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.get_default_chunk_interval()
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_default_value('chunk_interval')::pg_catalog.interval;
$func$
    LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.get_default_chunk_interval()
    IS 'Get the default chunk interval for all metrics';
GRANT EXECUTE ON FUNCTION prom_api.get_default_chunk_interval() TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_metric_chunk_interval(metric_name TEXT, chunk_interval INTERVAL)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    --use get_or_create_metric_table_name because we want to be able to set /before/ any data is ingested
    --needs to run before update so row exists before update.
    SELECT _prom_catalog.get_or_create_metric_table_name(set_metric_chunk_interval.metric_name);

    UPDATE _prom_catalog.metric SET default_chunk_interval = false
    WHERE id IN (SELECT id FROM _prom_catalog.get_metric_table_name_if_exists('prom_data', set_metric_chunk_interval.metric_name));

    SELECT _prom_catalog.set_chunk_interval_on_metric_table(metric_name, chunk_interval);

    SELECT true;
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.set_metric_chunk_interval(TEXT, INTERVAL)
IS 'set a chunk interval for a specific metric (this overrides the default)';
GRANT EXECUTE ON FUNCTION prom_api.set_metric_chunk_interval(TEXT, INTERVAL) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.get_metric_chunk_interval(metric_name TEXT)
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
    DECLARE
    _table_name TEXT;
    _is_default BOOLEAN;
    _chunk_interval INTERVAL;
    BEGIN
        SELECT table_name, default_chunk_interval
        INTO STRICT _table_name, _is_default
        FROM _prom_catalog.metric WHERE table_schema = 'prom_data' AND metric.metric_name = get_metric_chunk_interval.metric_name;
        IF _is_default THEN
            RETURN prom_api.get_default_chunk_interval();
        END IF;

        SELECT time_interval
        INTO STRICT _chunk_interval
        FROM timescaledb_information.dimensions
        WHERE hypertable_schema = 'prom_data' AND hypertable_name = _table_name AND column_name = 'time';

        RETURN _chunk_interval;
    END
$func$
LANGUAGE plpgsql;
COMMENT ON FUNCTION prom_api.get_metric_chunk_interval(TEXT)
    IS 'Get the chunk interval for a specific metric, or the default chunk interval if not explicitly set';
GRANT EXECUTE ON FUNCTION prom_api.get_metric_chunk_interval(TEXT) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.reset_metric_chunk_interval(metric_name TEXT)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    UPDATE _prom_catalog.metric SET default_chunk_interval = true
    WHERE id = (SELECT id FROM _prom_catalog.get_metric_table_name_if_exists('prom_data', metric_name));

    SELECT _prom_catalog.set_chunk_interval_on_metric_table(metric_name,
        _prom_catalog.get_default_chunk_interval());

    SELECT true;
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.reset_metric_chunk_interval(TEXT)
IS 'resets the chunk interval for a specific metric to using the default';
GRANT EXECUTE ON FUNCTION prom_api.reset_metric_chunk_interval(TEXT) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.get_metric_retention_period(schema_name TEXT, metric_name TEXT)
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(m.retention_period, _prom_catalog.get_default_retention_period())
    FROM _prom_catalog.metric m
    WHERE id IN (SELECT id FROM _prom_catalog.get_metric_table_name_if_exists(schema_name, get_metric_retention_period.metric_name))
    UNION ALL
    SELECT _prom_catalog.get_default_retention_period()
    LIMIT 1
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_metric_retention_period(TEXT, TEXT) TO prom_reader;

-- convenience function for returning retention period of raw metrics
-- without the need to specify the schema
CREATE OR REPLACE FUNCTION _prom_catalog.get_metric_retention_period(metric_name TEXT)
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT *
    FROM _prom_catalog.get_metric_retention_period('prom_data', get_metric_retention_period.metric_name)
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_metric_retention_period(TEXT) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.set_default_retention_period(retention_period INTERVAL)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT _prom_catalog.set_default_value('retention_period', retention_period::text);
    SELECT true;
$$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.set_default_retention_period(INTERVAL)
IS 'set the retention period for any metrics (existing and new) without an explicit override';
GRANT EXECUTE ON FUNCTION prom_api.set_default_retention_period(INTERVAL) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_metric_retention_period(schema_name TEXT, metric_name TEXT, new_retention_period INTERVAL)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    r _prom_catalog.metric;
    _is_cagg BOOLEAN;
    _cagg_schema NAME;
    _cagg_name NAME;
BEGIN
    --use get_or_create_metric_table_name because we want to be able to set /before/ any data is ingested
    --needs to run before update so row exists before update.
    PERFORM _prom_catalog.get_or_create_metric_table_name(set_metric_retention_period.metric_name)
    WHERE schema_name = 'prom_data';

    --check if its a metric view with cagg
    SELECT is_cagg, cagg_schema, cagg_name
    INTO _is_cagg, _cagg_schema, _cagg_name
    FROM _prom_catalog.get_cagg_info(schema_name, metric_name);

    IF NOT _is_cagg OR (_cagg_name = metric_name AND _cagg_schema = schema_name) THEN
        UPDATE _prom_catalog.metric m SET retention_period = new_retention_period
        WHERE m.table_schema = schema_name
        AND m.metric_name = set_metric_retention_period.metric_name;

        RETURN true;
    END IF;

    --handles 2-step aggregatop
    RAISE NOTICE 'Setting data retention period for all metrics with underlying continuous aggregate %.%', _cagg_schema, _cagg_name;

    FOR r IN
        SELECT m.*
        FROM information_schema.view_table_usage v
        INNER JOIN _prom_catalog.metric m
          ON (m.table_name = v.view_name AND m.table_schema = v.view_schema)
        WHERE v.table_name = _cagg_name
          AND v.table_schema = _cagg_schema
    LOOP
        RAISE NOTICE 'Setting data retention for metrics %.%', r.table_schema, r.metric_name;

        UPDATE _prom_catalog.metric m
        SET retention_period = new_retention_period
        WHERE m.table_schema = r.table_schema
        AND m.metric_name = r.metric_name;
    END LOOP;

    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION prom_api.set_metric_retention_period(TEXT, TEXT, INTERVAL)
IS 'set a retention period for a specific metric (this overrides the default)';
GRANT EXECUTE ON FUNCTION prom_api.set_metric_retention_period(TEXT, TEXT, INTERVAL)TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_metric_retention_period(metric_name TEXT, new_retention_period INTERVAL)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT prom_api.set_metric_retention_period('prom_data', metric_name, new_retention_period);
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.set_metric_retention_period(TEXT, INTERVAL)
IS 'set a retention period for a specific raw metric in default schema (this overrides the default)';
GRANT EXECUTE ON FUNCTION prom_api.set_metric_retention_period(TEXT, INTERVAL) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.get_metric_retention_period(metric_schema TEXT, metric_name TEXT)
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_metric_retention_period(metric_schema, metric_name);
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.get_metric_retention_period(TEXT, TEXT)
IS 'get the retention period for a specific metric';
GRANT EXECUTE ON FUNCTION prom_api.get_metric_retention_period(TEXT, TEXT) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.get_metric_retention_period(metric_name TEXT)
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT _prom_catalog.get_metric_retention_period('prom_data', metric_name);
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.get_metric_retention_period(TEXT)
IS 'get the retention period for a specific metric';
GRANT EXECUTE ON FUNCTION prom_api.get_metric_retention_period(TEXT) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.get_default_metric_retention_period()
    RETURNS INTERVAL
    SET search_path = pg_catalog, pg_temp
AS $func$
SELECT _prom_catalog.get_default_retention_period();
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.get_default_metric_retention_period()
IS 'get the default retention period for all metrics';
GRANT EXECUTE ON FUNCTION prom_api.get_default_metric_retention_period() TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.reset_metric_retention_period(schema_name TEXT, metric_name TEXT)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    r _prom_catalog.metric;
    _is_cagg BOOLEAN;
    _cagg_schema NAME;
    _cagg_name NAME;
BEGIN

    --check if its a metric view with cagg
    SELECT is_cagg, cagg_schema, cagg_name
    INTO _is_cagg, _cagg_schema, _cagg_name
    FROM _prom_catalog.get_cagg_info(schema_name, metric_name);

    IF NOT _is_cagg OR (_cagg_name = metric_name AND _cagg_schema = schema_name) THEN
        UPDATE _prom_catalog.metric m SET retention_period = NULL
        WHERE m.table_schema = schema_name
        AND m.metric_name = reset_metric_retention_period.metric_name;

        RETURN true;
    END IF;

    RAISE NOTICE 'Resetting data retention period for all metrics with underlying continuous aggregate %.%', _cagg_schema, _cagg_name;

    FOR r IN
        SELECT m.*
        FROM information_schema.view_table_usage v
        INNER JOIN _prom_catalog.metric m
          ON (m.table_name = v.view_name AND m.table_schema = v.view_schema)
        WHERE v.table_name = _cagg_name
          AND v.table_schema = _cagg_schema
    LOOP
        RAISE NOTICE 'Resetting data retention for metrics %.%', r.table_schema, r.metric_name;

        UPDATE _prom_catalog.metric m
        SET retention_period = NULL
        WHERE m.table_schema = r.table_schema
        AND m.metric_name = r.metric_name;
    END LOOP;

    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION prom_api.reset_metric_retention_period(TEXT, TEXT)
IS 'resets the retention period for a specific metric to using the default';
GRANT EXECUTE ON FUNCTION prom_api.reset_metric_retention_period(TEXT, TEXT) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.reset_metric_retention_period(metric_name TEXT)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT prom_api.reset_metric_retention_period('prom_data', metric_name);
$func$
LANGUAGE SQL;
COMMENT ON FUNCTION prom_api.reset_metric_retention_period(TEXT)
IS 'resets the retention period for a specific raw metric in the default schema to using the default retention period';
GRANT EXECUTE ON FUNCTION prom_api.reset_metric_retention_period(TEXT) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.get_metric_compression_setting(metric_name TEXT)
    RETURNS BOOLEAN
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    can_compress boolean;
    result boolean;
    metric_table_name text;
BEGIN
    SELECT exists(select * from pg_proc where proname = 'compress_chunk')
    INTO STRICT can_compress;

    IF NOT can_compress THEN
        RETURN FALSE;
    END IF;

    SELECT table_name
    INTO STRICT metric_table_name
    FROM _prom_catalog.get_metric_table_name_if_exists('prom_data', metric_name);

    IF _prom_catalog.get_timescale_major_version() >= 2  THEN
        SELECT compression_enabled
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema ='prom_data'
          AND hypertable_name = metric_table_name
        INTO STRICT result;
    ELSE
        SELECT EXISTS (
            SELECT FROM _timescaledb_catalog.hypertable h
            WHERE h.schema_name = 'prom_data'
            AND h.table_name = metric_table_name
            AND h.compressed_hypertable_id IS NOT NULL)
        INTO result;
    END IF;
    RETURN result;
END
$$
LANGUAGE PLPGSQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_metric_compression_setting(TEXT) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.set_default_compression_setting(compression_setting BOOLEAN)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    can_compress BOOLEAN;
BEGIN
    IF compression_setting = _prom_catalog.get_default_compression_setting() THEN
        RETURN TRUE;
    END IF;

    SELECT exists(select * from pg_proc where proname = 'compress_chunk')
    INTO STRICT can_compress;

    IF NOT can_compress AND compression_setting THEN
        RAISE EXCEPTION 'Cannot enable metrics compression, feature not found';
    END IF;

    PERFORM _prom_catalog.set_default_value('metric_compression', compression_setting::text);

    PERFORM prom_api.set_compression_on_metric_table(table_name, compression_setting)
    FROM _prom_catalog.metric
    WHERE default_compression;
    RETURN true;
END
$$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION prom_api.set_default_compression_setting(BOOLEAN)
IS 'set the compression setting for any metrics (existing and new) without an explicit override';
GRANT EXECUTE ON FUNCTION prom_api.set_default_compression_setting(BOOLEAN) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_metric_compression_setting(metric_name TEXT, new_compression_setting BOOLEAN)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    can_compress boolean;
    metric_table_name text;
BEGIN
    --if already set to desired value, nothing to do
    IF _prom_catalog.get_metric_compression_setting(metric_name) = new_compression_setting THEN
        RETURN TRUE;
    END IF;

    SELECT exists(select * from pg_proc where proname = 'compress_chunk')
    INTO STRICT can_compress;

    --if compression is missing, cannot enable it
    IF NOT can_compress AND new_compression_setting THEN
        RAISE EXCEPTION 'Cannot enable metrics compression, feature not found';
    END IF;

    --use get_or_create_metric_table_name because we want to be able to set /before/ any data is ingested
    --needs to run before update so row exists before update.
    SELECT table_name
    INTO STRICT metric_table_name
    FROM _prom_catalog.get_or_create_metric_table_name(set_metric_compression_setting.metric_name);

    PERFORM prom_api.set_compression_on_metric_table(metric_table_name, new_compression_setting);

    UPDATE _prom_catalog.metric
    SET default_compression = false
    WHERE table_name = metric_table_name;

    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION prom_api.set_metric_compression_setting(TEXT, BOOLEAN)
IS 'set a compression setting for a specific metric (this overrides the default)';
GRANT EXECUTE ON FUNCTION prom_api.set_metric_compression_setting(TEXT, BOOLEAN) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.set_compression_on_metric_table(metric_table_name TEXT, compression_setting BOOLEAN)
    RETURNS void
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
   _compressed_schema text;
   _compressed_hypertable TEXT;
BEGIN
    IF _prom_catalog.is_timescaledb_oss() THEN
        RAISE NOTICE 'Compression not available in TimescaleDB-OSS. Cannot set compression on "%" metric table name', metric_table_name;
        RETURN;
    END IF;
    IF compression_setting THEN
        EXECUTE format($$
            ALTER TABLE prom_data.%I SET (
                timescaledb.compress,
                timescaledb.compress_segmentby = 'series_id',
                timescaledb.compress_orderby = 'time, value'
            ); $$, metric_table_name);

        SELECT c.schema_name, c.table_name
        INTO STRICT _compressed_schema, _compressed_hypertable
        FROM _timescaledb_catalog.hypertable h
        INNER JOIN _timescaledb_catalog.hypertable c ON (h.compressed_hypertable_id= c.id)
        WHERE h.schema_name = 'prom_data' AND h.table_name = metric_table_name;

        --Make the compressed tables freeze on every vacuum run. They won't be changed
        --later anyway and there is no point requiring another vacuum before wraparound.
        --Also, make sure autovacuum runs quickly after initial creation, by setting the
        --threshold low.
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
            --pg12 doesn't have autovacuum_vacuum_insert_threshold. You should still freeze if you get the chance.
            EXECUTE FORMAT($$
                ALTER TABLE %I.%I SET
                (
                    autovacuum_freeze_min_age=0,
                    autovacuum_freeze_table_age=0
                )
            $$, _compressed_schema, _compressed_hypertable);
        END IF;

        --rc4 of multinode doesn't properly hand down compression when turned on
        --inside of a function; this gets around that.
        IF _prom_catalog.is_multinode() THEN
            CALL public.distributed_exec(
                format($$
                ALTER TABLE prom_data.%I SET (
                    timescaledb.compress,
                   timescaledb.compress_segmentby = 'series_id',
                   timescaledb.compress_orderby = 'time, value'
               ); $$, metric_table_name),
               transactional => false);
        END IF;

        --chunks where the end time is before now()-1 hour will be compressed
        --per-ht compression policy only used for timescale 1.x
        IF _prom_catalog.get_timescale_major_version() < 2 THEN
            PERFORM public.add_compress_chunks_policy(format('prom_data.%I', metric_table_name), INTERVAL '1 hour');
        END IF;
    ELSE
        IF _prom_catalog.get_timescale_major_version() < 2 THEN
            PERFORM public.remove_compress_chunks_policy(format('prom_data.%I', metric_table_name));
        END IF;

        CALL _prom_catalog.decompress_chunks_after(metric_table_name::name, timestamptz '-Infinity', transactional=>true);

        EXECUTE format($$
            ALTER TABLE prom_data.%I SET (
                timescaledb.compress = false
            ); $$, metric_table_name);
    END IF;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION prom_api.set_compression_on_metric_table(TEXT, BOOLEAN) FROM PUBLIC;
COMMENT ON FUNCTION prom_api.set_compression_on_metric_table(TEXT, BOOLEAN)
IS 'set a compression for a specific metric table';
GRANT EXECUTE ON FUNCTION prom_api.set_compression_on_metric_table(TEXT, BOOLEAN) TO prom_admin;


CREATE OR REPLACE FUNCTION prom_api.reset_metric_compression_setting(metric_name TEXT)
    RETURNS BOOLEAN
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    metric_table_name text;
BEGIN
    SELECT table_name
    INTO STRICT metric_table_name
    FROM _prom_catalog.get_or_create_metric_table_name(reset_metric_compression_setting.metric_name);

    UPDATE _prom_catalog.metric
    SET default_compression = true
    WHERE table_name = metric_table_name;

    PERFORM prom_api.set_compression_on_metric_table(metric_table_name, _prom_catalog.get_default_compression_setting());
    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
COMMENT ON FUNCTION prom_api.reset_metric_compression_setting(TEXT)
IS 'resets the compression setting for a specific metric to using the default';
GRANT EXECUTE ON FUNCTION prom_api.reset_metric_compression_setting(TEXT) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.epoch_abort(user_epoch BIGINT)
    RETURNS VOID
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE db_epoch BIGINT;
BEGIN
    SELECT current_epoch FROM _prom_catalog.ids_epoch LIMIT 1
        INTO db_epoch;
    RAISE EXCEPTION 'epoch % to old to continue INSERT, current: %',
        user_epoch, db_epoch
        USING ERRCODE='PS001';
END;
$func$ LANGUAGE PLPGSQL;
COMMENT ON FUNCTION _prom_catalog.epoch_abort(BIGINT)
IS 'ABORT an INSERT transaction due to the ID epoch being out of date';
GRANT EXECUTE ON FUNCTION _prom_catalog.epoch_abort TO prom_writer;

-- Given a `metric_schema`, `metric_table`, and `series_table`, this function
-- returns all series ids in `potential_series_ids` which are not referenced by
-- data newer than `newer_than` in any metric table.
-- Note: See _prom_catalog.mark_series_to_be_dropped_as_unused for context.
CREATE OR REPLACE FUNCTION _prom_catalog.get_confirmed_unused_series(
    metric_schema TEXT, metric_table TEXT, series_table TEXT, potential_series_ids BIGINT[], newer_than TIMESTAMPTZ
)
    RETURNS BIGINT[]
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    r RECORD;
    check_time_condition TEXT;
BEGIN
    -- Note: when using TimescaleDB's Continuous Aggregates to downsample, a
    -- materialized metric view may contain rows which reference one of the
    -- series ids in potential_series_ids. So we look through all metric
    -- entries which have declared a dependency on the series table.
    FOR r IN
        SELECT *
        FROM _prom_catalog.metric m
        WHERE m.series_table = get_confirmed_unused_series.series_table
    LOOP

        check_time_condition := '';
        IF r.table_schema = metric_schema::NAME AND r.table_name = metric_table::NAME THEN
            check_time_condition := FORMAT('AND time >= %L', newer_than);
        END IF;

        --at each iteration of the loop filter potential_series_ids to only
        --have those series ids that don't exist in the metric tables.
        EXECUTE format(
        $query$
            SELECT array_agg(potential_series.series_id)
            FROM unnest($1) as potential_series(series_id)
            LEFT JOIN LATERAL(
                SELECT 1
                FROM  %1$I.%2$I data_exists
                WHERE data_exists.series_id = potential_series.series_id
                %3$s
                --use chunk append + more likely to find something starting at earliest time
                ORDER BY time ASC
                LIMIT 1
            ) as lateral_exists(indicator) ON (true)
            WHERE lateral_exists.indicator IS NULL
        $query$, r.table_schema, r.table_name, check_time_condition)
        USING potential_series_ids
        INTO potential_series_ids;

    END LOOP;

    RETURN potential_series_ids;
END
$func$
LANGUAGE PLPGSQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_confirmed_unused_series(TEXT, TEXT, TEXT, BIGINT[], TIMESTAMPTZ) TO prom_maintenance;
COMMENT ON FUNCTION _prom_catalog.get_confirmed_unused_series(TEXT, TEXT, TEXT, BIGINT[], TIMESTAMPTZ)
    IS
'
Given a `metric_schema`, `metric_table`, and `series_table`, this function
returns all series ids in `potential_series_ids` which are not referenced by
data newer than `newer_than` in any metric table.
Note: See _prom_catalog.mark_series_to_be_dropped_as_unused for context.
';

-- Marks series which we will drop soon as unused.
-- A series is unused if there is no data newer than `drop_point` which
-- references that series.
-- Note: This function can only mark a series as unused if there is still
-- data which references that series.
-- This function is designed to be used in the context of dropping metric
-- chunks, see `_prom_catalog.drop_metric_chunks`.
CREATE OR REPLACE FUNCTION _prom_catalog.mark_series_to_be_dropped_as_unused(
    metric_schema TEXT, metric_table TEXT, metric_series_table TEXT, drop_point TIMESTAMPTZ
)
    RETURNS VOID
    --security definer to add jobs as the logged-in user
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    check_time TIMESTAMPTZ;
BEGIN

    -- We determine if a series is unused by "looking back" over data older
    -- than `drop_point` and getting all distinct series ids in the data.
    -- This set of series will likely contain some series which are not unused.
    -- We will need to eliminate all of the series which are not unused by
    -- looking through all of the data. Before we do that, we can perform a
    -- simple optimisation: any series which are also referenced between
    -- `drop_point` and (`drop_point` + 1 hour) are not unused, so we can
    -- discard those from the candidate list, and do a full check on the rest.
    --
    --                   drop_point     check_time
    --                       v              v
    --     time ------------------------------->
    --   series   (S1,S2,S3) |    (S3,S4)   |
    --
    -- In the example above, we find series (S1,S2,S3) referenced in the data
    -- older than `drop_point`. We also find series (S3,S4) in the data between
    -- `drop_point` and `check_time`. We can discard S3 from the set of series
    -- that we will check.
    SELECT drop_point OPERATOR(pg_catalog.+) pg_catalog.interval '1 hour'
    INTO check_time;

    EXECUTE format(
    $query$
        WITH potentially_drop_series AS (
            SELECT distinct series_id
            FROM %1$I.%2$I
            WHERE time < %4$L
            EXCEPT
            SELECT distinct series_id
            FROM %1$I.%2$I
            WHERE time >= %4$L AND time < %5$L
        ), confirmed_drop_series AS (
            SELECT _prom_catalog.get_confirmed_unused_series('%1$s','%2$s','%3$s', array_agg(series_id), %5$L) as ids
            FROM potentially_drop_series
        ) -- we want this next statement to be the last one in the txn since it could block series fetch (both of them update delete_epoch)
        UPDATE prom_data_series.%3$I SET delete_epoch = current_epoch+1
        FROM _prom_catalog.ids_epoch
        WHERE delete_epoch IS NULL
            AND id IN (SELECT unnest(ids) FROM confirmed_drop_series)
    $query$, metric_schema, metric_table, metric_series_table, drop_point, check_time);
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.mark_series_to_be_dropped_as_unused(text, text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.mark_series_to_be_dropped_as_unused(text, text, text, timestamptz) TO prom_maintenance;
COMMENT ON FUNCTION _prom_catalog.mark_series_to_be_dropped_as_unused(text, text, text, timestamptz)
    IS
'
Marks series which we will drop soon as unused.
A series is unused if there is no data newer than `drop_point` which
references that series.
Note: This function can only mark a series as unused if there is still
data which references that series.
This function is designed to be used in the context of dropping metric
chunks, see `_prom_catalog.drop_metric_chunks`.
';

CREATE OR REPLACE FUNCTION _prom_catalog.delete_expired_series(
    metric_schema TEXT, metric_table TEXT, metric_series_table TEXT, ran_at TIMESTAMPTZ, present_epoch BIGINT, last_updated_epoch TIMESTAMPTZ
)
    RETURNS VOID
    --security definer to add jobs as the logged-in user
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    label_array int[];
    next_epoch BIGINT;
    deletion_epoch BIGINT;
    epoch_duration INTERVAL;
BEGIN
    next_epoch := present_epoch + 1;
    -- technically we can delete any ID <= current_epoch - 1
    -- but it's always safe to leave them around for a bit longer
    deletion_epoch := present_epoch - 4;

    EXECUTE format($query$
        -- recheck that the series IDs we might delete are actually dead
        WITH dead_series AS (
            SELECT potential.id
            FROM
            (
                SELECT id
                FROM prom_data_series.%3$I
                WHERE delete_epoch <= %4$L
            ) as potential
            LEFT JOIN LATERAL (
                SELECT 1
                FROM %1$I.%2$I metric_data
                WHERE metric_data.series_id = potential.id
                LIMIT 1
            ) as lateral_exists(indicator) ON (TRUE)
            WHERE indicator IS NULL
        ), deleted_series AS (
            DELETE FROM prom_data_series.%3$I
            WHERE delete_epoch <= %4$L
                AND id IN (SELECT id FROM dead_series) -- concurrency means we need this qual in both
            RETURNING id, labels
        ), resurrected_series AS (
            UPDATE prom_data_series.%3$I
            SET delete_epoch = NULL
            WHERE delete_epoch <= %4$L
                AND id NOT IN (SELECT id FROM dead_series) -- concurrency means we need this qual in both
        )
        SELECT ARRAY(SELECT DISTINCT unnest(labels) as label_id
            FROM deleted_series)
    $query$, metric_schema, metric_table, metric_series_table, deletion_epoch) INTO label_array;


    IF array_length(label_array, 1) > 0 THEN
        --jit interacts poorly why the multi-partition query below
        SET LOCAL jit = 'off';
        --needs to be a separate query and not a CTE since this needs to "see"
        --the series rows deleted above as deleted.
        --Note: we never delete metric name keys since there are check constraints that
        --rely on those ids not changing.
        EXECUTE format($query$
        WITH check_local_series AS (
                --the series table from which we just deleted is much more likely to have the label, so check that first to exclude most labels.
                SELECT label_id
                FROM unnest($1) as labels(label_id)
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM  prom_data_series.%1$I series_exists_local
                    WHERE series_exists_local.labels && ARRAY[labels.label_id]
                    LIMIT 1
                )
            ),
            confirmed_drop_labels AS (
                --do the global check to confirm
                SELECT label_id
                FROM check_local_series
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM  _prom_catalog.series series_exists
                    WHERE series_exists.labels && ARRAY[label_id]
                    LIMIT 1
                )
            )
            DELETE FROM _prom_catalog.label
            WHERE id IN (SELECT * FROM confirmed_drop_labels) AND key != '__name__';
        $query$, metric_series_table) USING label_array;

        SET LOCAL jit = DEFAULT;
    END IF;

    SELECT _prom_catalog.get_default_value('epoch_duration')::INTERVAL INTO STRICT epoch_duration;

    IF ran_at > last_updated_epoch + epoch_duration THEN
        -- we only want to increment the epoch every epoch_duration
        UPDATE _prom_catalog.ids_epoch
        SET (current_epoch, last_update_time) = (next_epoch, now())
        WHERE current_epoch < next_epoch;
    END IF;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.delete_expired_series(text, text, text, timestamptz, BIGINT, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.delete_expired_series(text, text, text, timestamptz, BIGINT, timestamptz) TO prom_maintenance;

CREATE OR REPLACE FUNCTION _prom_catalog.set_app_name(full_name text)
    RETURNS VOID
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    --setting a name that's too long creates superfluous NOTICE messages in the log
    SELECT set_config('application_name', substring(full_name for 63), false);
$func$
LANGUAGE SQL PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.set_app_name(text) TO prom_maintenance;

-- Get hypertable information for where data is stored for raw metrics and for
-- the materialized hypertable for cagg metrics. For non-materialized views return
-- no rows
CREATE OR REPLACE FUNCTION _prom_catalog.get_storage_hypertable_info(metric_schema_name text, metric_table_name text, is_view boolean)
    RETURNS TABLE (id int, hypertable_relation text)
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    agg_schema name;
    agg_name name;
    _is_cagg boolean;
    _materialized_hypertable_id int;
    _storage_hypertable_relation text;
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;

    IF NOT is_view THEN
        RETURN QUERY
        SELECT h.id, format('%I.%I', h.schema_name,  h.table_name)
        FROM _timescaledb_catalog.hypertable h
        WHERE h.schema_name = metric_schema_name
        AND h.table_name = metric_table_name;
        RETURN;
    END IF;

    SELECT is_cagg, materialized_hypertable_id, storage_hypertable_relation
    INTO _is_cagg, _materialized_hypertable_id, _storage_hypertable_relation
    FROM _prom_catalog.get_cagg_info(metric_schema_name, metric_table_name);

    IF NOT _is_cagg THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT _materialized_hypertable_id, _storage_hypertable_relation;
END
$$
LANGUAGE PLPGSQL STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_storage_hypertable_info(text, text, boolean) TO prom_reader;


--Get underlying metric view schema and name
--we need to support up to two levels of views to support 2-step caggs
CREATE OR REPLACE FUNCTION _prom_catalog.get_first_level_view_on_metric(metric_schema text, metric_table text)
    RETURNS TABLE (view_schema name, view_name name, metric_table_name name)
    --security definer to add jobs as the logged-in user
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    --RAISE WARNING 'checking view: % %', metric_schema, metric_table;
    RETURN QUERY
    SELECT v.view_schema::name, v.view_name::name, v.table_name::name
    FROM information_schema.view_table_usage v
    WHERE v.view_schema = metric_schema
    AND v.view_name = metric_table
    AND v.table_schema = 'prom_data';

    IF FOUND THEN
        RETURN;
    END IF;

    -- if first level not found, return 2nd level if any
    RETURN QUERY
    SELECT v2.view_schema::name, v2.view_name::name, v2.table_name::name
    FROM information_schema.view_table_usage v
    LEFT JOIN information_schema.view_table_usage v2
        ON (v2.view_schema = v.table_schema
            AND v2.view_name = v.table_name)
    WHERE v.view_schema = metric_schema
    AND v.view_name = metric_table
    AND v2.table_schema = 'prom_data';
    RETURN;
END
$$
LANGUAGE PLPGSQL STABLE;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.get_first_level_view_on_metric(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_first_level_view_on_metric(text, text) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_cagg_info(
    metric_schema text, metric_table text,
    OUT is_cagg BOOLEAN, OUT cagg_schema name, OUT cagg_name name, OUT metric_table_name name,
    OUT materialized_hypertable_id INT, OUT storage_hypertable_relation TEXT)
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    is_cagg := FALSE;
    SELECT *
    FROM _prom_catalog.get_first_level_view_on_metric(metric_schema, metric_table)
    INTO cagg_schema, cagg_name, metric_table_name;

    IF NOT FOUND THEN
      RETURN;
    END IF;

    -- for TSDB 2.x we return the view schema and name because functions like
    -- show_chunks don't work on materialized hypertables, which is a difference
    -- from 1.x version
    IF _prom_catalog.get_timescale_major_version() >= 2 THEN
        SELECT h.id, format('%I.%I', c.view_schema,  c.view_name)
        INTO materialized_hypertable_id, storage_hypertable_relation
        FROM timescaledb_information.continuous_aggregates c
        INNER JOIN _timescaledb_catalog.hypertable h
            ON (h.schema_name = c.materialization_hypertable_schema
                AND h.table_name = c.materialization_hypertable_name)
        WHERE c.view_schema = cagg_schema
        AND c.view_name = cagg_name;
    ELSE
        SELECT h.id, format('%I.%I', h.schema_name,  h.table_name)
        INTO materialized_hypertable_id, storage_hypertable_relation
        FROM timescaledb_information.continuous_aggregates c
        INNER JOIN _timescaledb_catalog.hypertable h
            ON (c.materialization_hypertable::text = format('%I.%I', h.schema_name,  h.table_name))
        WHERE c.view_name::text = format('%I.%I', cagg_schema, cagg_name);
    END IF;

    IF NOT FOUND THEN
      cagg_schema := NULL;
      cagg_name := NULL;
      metric_table_name := NULL;
      RETURN;
    END IF;

    is_cagg := true;
    return;
END
$$
LANGUAGE PLPGSQL STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_cagg_info(text, text) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.is_stale_marker(value double precision)
    RETURNS BOOLEAN
    -- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT pg_catalog.float8send(value) OPERATOR (pg_catalog.=) '\x7ff0000000000002'
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.is_stale_marker(double precision)
IS 'returns true if the value is a Prometheus stale marker';
GRANT EXECUTE ON FUNCTION prom_api.is_stale_marker(double precision) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.is_normal_nan(value double precision)
    RETURNS BOOLEAN
    -- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT pg_catalog.float8send(value) OPERATOR (pg_catalog.=) '\x7ff8000000000001'
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.is_normal_nan(double precision)
IS 'returns true if the value is a NaN';
GRANT EXECUTE ON FUNCTION prom_api.is_normal_nan(double precision) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.val(
        label_id INT)
    RETURNS TEXT
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT
        value
    FROM _prom_catalog.label
    WHERE
        id = label_id
$$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.val(INT)
IS 'returns the label value from a label id';
GRANT EXECUTE ON FUNCTION prom_api.val(INT) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.get_label_key_column_name_for_view(label_key text, id BOOLEAN)
    RETURNS NAME
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
  is_reserved boolean;
BEGIN
  SELECT label_key = ANY(ARRAY['time', 'value', 'series_id', 'labels'])
  INTO STRICT is_reserved;

  IF is_reserved THEN
    label_key := 'label_' || label_key;
  END IF;

  IF id THEN
    RETURN (_prom_catalog.get_or_create_label_key(label_key)).id_column_name;
  ELSE
    RETURN (_prom_catalog.get_or_create_label_key(label_key)).value_column_name;
  END IF;
END
$func$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_label_key_column_name_for_view(text, BOOLEAN) TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.create_series_view(
        metric_name text)
    RETURNS BOOLEAN
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
   label_value_cols text;
   view_name text;
   metric_id int;
   view_exists boolean;
BEGIN
    SELECT
        ',' || string_agg(
            format ('prom_api.val(series.labels[%s]) AS %I',pos::int, _prom_catalog.get_label_key_column_name_for_view(key, false))
        , ', ' ORDER BY pos)
    INTO STRICT label_value_cols
    FROM _prom_catalog.label_key_position lkp
    WHERE lkp.metric_name = create_series_view.metric_name and key != '__name__';

    SELECT m.table_name, m.id
    INTO STRICT view_name, metric_id
    FROM _prom_catalog.metric m
    WHERE m.metric_name = create_series_view.metric_name
    AND m.table_schema = 'prom_data';

    SELECT COUNT(*) > 0 into view_exists
    FROM pg_class
    WHERE
      relname = view_name AND
      relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'prom_series');

    EXECUTE FORMAT($$
        CREATE OR REPLACE VIEW prom_series.%1$I AS
        SELECT
            id AS series_id,
            labels
            %2$s
        FROM
            prom_data_series.%1$I AS series
        WHERE delete_epoch IS NULL
    $$, view_name, label_value_cols);

    IF NOT view_exists THEN
        EXECUTE FORMAT('GRANT SELECT ON prom_series.%1$I TO prom_reader', view_name);
        EXECUTE FORMAT('ALTER VIEW prom_series.%1$I OWNER TO prom_admin', view_name);
    END IF;
    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.create_series_view(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.create_series_view(text) TO prom_writer;

CREATE OR REPLACE FUNCTION _prom_catalog.create_metric_view(
        metric_name text)
    RETURNS BOOLEAN
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
   label_value_cols text;
   table_name text;
   metric_id int;
   view_exists boolean;
BEGIN
    SELECT
        ',' || string_agg(
            format ('series.labels[%s] AS %I',pos::int, _prom_catalog.get_label_key_column_name_for_view(key, true))
        , ', ' ORDER BY pos)
    INTO STRICT label_value_cols
    FROM _prom_catalog.label_key_position lkp
    WHERE lkp.metric_name = create_metric_view.metric_name and key != '__name__';

    SELECT m.table_name, m.id
    INTO STRICT table_name, metric_id
    FROM _prom_catalog.metric m
    WHERE m.metric_name = create_metric_view.metric_name
    AND m.table_schema = 'prom_data';

    SELECT COUNT(*) > 0 into view_exists
    FROM pg_class
    WHERE
      relname = table_name AND
      relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'prom_metric');

    EXECUTE FORMAT($$
        CREATE OR REPLACE VIEW prom_metric.%1$I AS
        SELECT
            data.time as time,
            data.value as value,
            data.series_id AS series_id,
            series.labels
            %2$s
        FROM
            prom_data.%1$I AS data
            LEFT JOIN prom_data_series.%1$I AS series ON (series.id = data.series_id)
    $$, table_name, label_value_cols);

    IF NOT view_exists THEN
        EXECUTE FORMAT('GRANT SELECT ON prom_metric.%1$I TO prom_reader', table_name);
        EXECUTE FORMAT('ALTER VIEW prom_metric.%1$I OWNER TO prom_admin', table_name);
    END IF;

    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.create_metric_view(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.create_metric_view(text) TO prom_writer;

CREATE OR REPLACE FUNCTION prom_api.register_metric_view(schema_name text, view_name text, refresh_interval INTERVAL = NULL, for_rollups BOOLEAN = false, if_not_exists BOOLEAN = false)
    RETURNS BOOLEAN
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
   agg_schema name;
   agg_name name;
   metric_table_name name;
   column_count int;
BEGIN
    -- check if table/view exists
    PERFORM * FROM information_schema.tables
    WHERE  table_schema = register_metric_view.schema_name
    AND    table_name   = register_metric_view.view_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'cannot register non-existent metric view with name % in specified schema %', view_name, schema_name;
    END IF;

    -- cannot register view in data schema
    IF schema_name = 'prom_data' THEN
        RAISE EXCEPTION 'cannot register metric view in prom_data schema';
    END IF;

    IF for_rollups THEN
        metric_table_name := view_name;
        agg_name := view_name;
        agg_schema := schema_name;
    ELSE
        -- check if view is based on a metric from prom_data
        -- we check for two levels so we can support 2-step continuous aggregates
        SELECT v.view_schema, v.view_name, v.metric_table_name
        INTO agg_schema, agg_name, metric_table_name
        FROM _prom_catalog.get_first_level_view_on_metric(schema_name, view_name) v;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'view with name % not based on a metric table from prom_data schema', view_name;
        END IF;
    END IF;

    -- check if the view contains necessary columns with the correct types
    SELECT count(*) FROM information_schema.columns
    INTO column_count
    WHERE table_schema = register_metric_view.schema_name
    AND table_name   = register_metric_view.view_name
    AND ((column_name = 'time' AND data_type = 'timestamp with time zone')
    OR (column_name = 'series_id' AND data_type = 'bigint')
    OR data_type = 'double precision');

    -- We only handle automatic refresh if refresh_interval is applied. Otherwise
    -- we ask the user to care about refreshing this Cagg.
    IF refresh_interval IS NULL THEN
        RAISE NOTICE 'Automatic refresh is disabled since refresh_interval is NULL. Please create refresh policy for this Cagg';
    ELSE
        CALL _prom_catalog.create_cagg_refresh_job(refresh_interval);
    END IF;

    IF column_count < 3 THEN
        RAISE EXCEPTION 'view must contain time (data type: timestamp with time zone), series_id (data type: bigint), and at least one column with double precision data type';
    END IF;

    -- insert into metric table
--     raise warning 'view_name -> %, view_name -> %, schema_name -> %, metric_table_name -> %, refresh_interval -> %', register_metric_view.view_name, register_metric_view.view_name, register_metric_view.schema_name, metric_table_name, refresh_interval;
    INSERT INTO _prom_catalog.metric (metric_name, table_name, table_schema, series_table, is_view, creation_completed, view_refresh_interval)
    VALUES (register_metric_view.view_name, register_metric_view.view_name, register_metric_view.schema_name, metric_table_name, true, true, refresh_interval)
    ON CONFLICT DO NOTHING;

    IF NOT FOUND THEN
        IF register_metric_view.if_not_exists THEN
            RAISE NOTICE 'metric with same name and schema already exists';
            RETURN FALSE;
        ELSE
            RAISE EXCEPTION 'metric with the same name and schema already exists, could not register';
        END IF;
    END IF;

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO prom_reader', register_metric_view.schema_name);
    EXECUTE format('GRANT SELECT ON TABLE %I.%I TO prom_reader', register_metric_view.schema_name, register_metric_view.view_name);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO prom_reader', agg_schema);
    EXECUTE format('GRANT SELECT ON TABLE %I.%I TO prom_reader', agg_schema, agg_name);

    PERFORM *
    FROM _prom_catalog.get_storage_hypertable_info(agg_schema, agg_name, true);

    RETURN true;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION prom_api.register_metric_view(text, text, interval, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION prom_api.register_metric_view(text, text, interval, boolean, boolean) TO prom_admin;

CREATE OR REPLACE FUNCTION prom_api.unregister_metric_view(schema_name text, view_name text, if_exists BOOLEAN = false)
    RETURNS BOOLEAN
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
   metric_table_name name;
   column_count int;
BEGIN
    DELETE FROM _prom_catalog.metric
    WHERE unregister_metric_view.schema_name = table_schema
    AND unregister_metric_view.view_name = table_name
    AND is_view = TRUE;

    IF NOT FOUND THEN
        IF unregister_metric_view.if_exists THEN
            RAISE NOTICE 'metric with specified name and schema does not exist';
            RETURN FALSE;
        ELSE
            RAISE EXCEPTION 'metric with specified name and schema does not exist, could not unregister';
        END IF;
    END IF;

    RETURN TRUE;
END
$func$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION prom_api.unregister_metric_view(text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION prom_api.unregister_metric_view(text, text, boolean) TO prom_admin;

CREATE OR REPLACE FUNCTION _prom_catalog.delete_series_from_metric(name text, series_ids bigint[])
    RETURNS BIGINT
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
    metric_table name;
    delete_stmt text;
    delete_query text;
    rows_affected bigint;
    num_rows_deleted bigint := 0;
BEGIN
    SELECT table_name INTO metric_table FROM _prom_catalog.metric m WHERE m.metric_name=name AND m.is_view = false;
    IF _prom_catalog.is_timescaledb_installed() THEN
        FOR delete_stmt IN
            SELECT FORMAT('DELETE FROM %1$I.%2$I WHERE series_id = ANY($1)', schema_name, table_name)
            FROM (
                SELECT (COALESCE(chc, ch)).* FROM pg_class c
                    INNER JOIN pg_namespace n ON c.relnamespace = n.oid
                    INNER JOIN _timescaledb_catalog.chunk ch ON (ch.schema_name, ch.table_name) = (n.nspname, c.relname)
                    LEFT JOIN _timescaledb_catalog.chunk chc ON ch.compressed_chunk_id = chc.id
                WHERE c.oid IN (SELECT public.show_chunks(format('%I.%I','prom_data', metric_table))::oid)
                ) a
        LOOP
            EXECUTE delete_stmt USING series_ids;
            GET DIAGNOSTICS rows_affected = ROW_COUNT;
            num_rows_deleted = num_rows_deleted + rows_affected;
        END LOOP;
    ELSE
        EXECUTE FORMAT('DELETE FROM prom_data.%1$I WHERE series_id = ANY($1)', metric_table) USING series_ids;
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        num_rows_deleted = num_rows_deleted + rows_affected;
    END IF;
    PERFORM _prom_catalog.delete_series_catalog_row(metric_table, series_ids);
    RETURN num_rows_deleted;
END;
$$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.delete_series_from_metric(text, bigint[])FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.delete_series_from_metric(text, bigint[]) to prom_modifier;

-- the following function requires timescaledb ↓↓↓↓
DO $block$
BEGIN
IF NOT _prom_catalog.is_timescaledb_installed() THEN
    RETURN;
END IF;
    CREATE OR REPLACE FUNCTION _prom_catalog.hypertable_local_size(schema_name_in text)
    RETURNS TABLE(hypertable_name text, table_bytes bigint, index_bytes bigint, toast_bytes bigint, total_bytes bigint)
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $function$
        SELECT
            ch.hypertable_name::text as hypertable_name,
            (COALESCE(sum(ch.total_bytes), 0) - COALESCE(sum(ch.index_bytes), 0) - COALESCE(sum(ch.toast_bytes), 0) + COALESCE(sum(ch.compressed_heap_size), 0))::bigint + pg_relation_size(format('%I.%I', ch.hypertable_schema, ch.hypertable_name)::regclass)::bigint AS heap_bytes,
            (COALESCE(sum(ch.index_bytes), 0) + COALESCE(sum(ch.compressed_index_size), 0))::bigint + pg_indexes_size(format('%I.%I', ch.hypertable_schema, ch.hypertable_name)::regclass)::bigint AS index_bytes,
            (COALESCE(sum(ch.toast_bytes), 0) + COALESCE(sum(ch.compressed_toast_size), 0))::bigint AS toast_bytes,
            (COALESCE(sum(ch.total_bytes), 0) + COALESCE(sum(ch.compressed_heap_size), 0) + COALESCE(sum(ch.compressed_index_size), 0) + COALESCE(sum(ch.compressed_toast_size), 0))::bigint + pg_total_relation_size(format('%I.%I', ch.hypertable_schema, ch.hypertable_name)::regclass)::bigint AS total_bytes
        FROM _timescaledb_internal.hypertable_chunk_local_size ch
        WHERE ch.hypertable_schema = schema_name_in
        GROUP BY ch.hypertable_name, ch.hypertable_schema;
    $function$
    LANGUAGE sql STRICT STABLE;
    REVOKE ALL ON FUNCTION _prom_catalog.hypertable_local_size(text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION _prom_catalog.hypertable_local_size(text) to prom_reader;
END;
$block$
;

-- the following function requires timescaledb ↓↓↓↓
DO $block$
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;
    CREATE OR REPLACE FUNCTION _prom_catalog.hypertable_node_up(schema_name_in text)
    RETURNS TABLE(hypertable_name text, node_name text, node_up boolean)
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $function$
        -- list of distributed hypertables and whether or not the associated data node is up
        -- only ping each distinct data node once and no more
        -- there is no guarantee that a node will stay "up" for the duration of a transaction
        -- but we don't want to pay the penalty of asking more than once, so we mark this
        -- function as stable to allow the results to be cached
        WITH dht AS MATERIALIZED (
            -- list of distributed hypertables
            SELECT
                ht.table_name,
                s.node_name
            FROM _timescaledb_catalog.hypertable ht
            JOIN _timescaledb_catalog.hypertable_data_node s ON (
                ht.replication_factor > 0 AND s.hypertable_id = ht.id
            )
            WHERE ht.schema_name = schema_name_in
        ),
        up AS MATERIALIZED (
            -- list of nodes we care about and whether they are up
            SELECT
                x.node_name,
                _timescaledb_internal.ping_data_node(x.node_name) AS node_up
            FROM (
                SELECT DISTINCT dht.node_name -- only ping each node once
                FROM dht
            ) x
        )
        SELECT
            dht.table_name::text as hypertable_name,
            dht.node_name::text as node_name,
            up.node_up
        FROM dht
        JOIN up ON (dht.node_name = up.node_name)
    $function$
    LANGUAGE sql
    STRICT STABLE;
    REVOKE ALL ON FUNCTION _prom_catalog.hypertable_node_up(text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION _prom_catalog.hypertable_node_up(text) to prom_reader;
END;
$block$
;

-- the following function requires timescaledb ↓↓↓↓
DO $block$
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;
    CREATE OR REPLACE FUNCTION _prom_catalog.hypertable_remote_size(schema_name_in text)
    RETURNS TABLE(hypertable_name text, table_bytes bigint, index_bytes bigint, toast_bytes bigint, total_bytes bigint)
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $function$
        SELECT
            dht.hypertable_name::text as hypertable_name,
            sum(x.table_bytes)::bigint AS table_bytes,
            sum(x.index_bytes)::bigint AS index_bytes,
            sum(x.toast_bytes)::bigint AS toast_bytes,
            sum(x.total_bytes)::bigint AS total_bytes
        FROM _prom_catalog.hypertable_node_up(schema_name_in) dht
        LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_hypertable_info(
            CASE WHEN dht.node_up THEN
                dht.node_name
            ELSE
                NULL
            END, schema_name_in, dht.hypertable_name) x ON true
        GROUP BY dht.hypertable_name
    $function$
    LANGUAGE sql
    STRICT STABLE;
    REVOKE ALL ON FUNCTION _prom_catalog.hypertable_remote_size(text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION _prom_catalog.hypertable_remote_size(text) to prom_reader;
END;
$block$
;

-- the following function requires timescaledb ↓↓↓↓
DO $block$
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;
    CREATE OR REPLACE FUNCTION _prom_catalog.hypertable_compression_stats_for_schema(schema_name_in text)
    RETURNS TABLE(hypertable_name text, total_chunks bigint, number_compressed_chunks bigint, before_compression_total_bytes bigint, after_compression_total_bytes bigint)
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $function$
        SELECT
            x.hypertable_name::text as hypertable_name,
            count(*)::bigint AS total_chunks,
            (count(*) FILTER (WHERE x.compression_status = 'Compressed'))::bigint AS number_compressed_chunks,
            sum(x.before_compression_total_bytes)::bigint AS before_compression_total_bytes,
            sum(x.after_compression_total_bytes)::bigint AS after_compression_total_bytes
        FROM
        (
            -- local hypertables
            SELECT
                ch.hypertable_name,
                ch.compression_status,
                ch.uncompressed_total_size AS before_compression_total_bytes,
                ch.compressed_total_size AS after_compression_total_bytes,
                NULL::text AS node_name
            FROM _timescaledb_internal.compressed_chunk_stats ch
            WHERE ch.hypertable_schema = schema_name_in
            UNION ALL
            -- distributed hypertables
            SELECT
                dht.hypertable_name,
                ch.compression_status,
                ch.before_compression_total_bytes,
                ch.after_compression_total_bytes,
                dht.node_name
            FROM _prom_catalog.hypertable_node_up(schema_name_in) dht
            LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_compressed_chunk_stats (
                CASE WHEN dht.node_up THEN
                    dht.node_name
                ELSE
                    NULL
                END, schema_name_in, dht.hypertable_name) ch ON true
            WHERE ch.chunk_name IS NOT NULL
        ) x
        GROUP BY x.hypertable_name
    $function$
    LANGUAGE sql
    STRICT STABLE;
    REVOKE ALL ON FUNCTION _prom_catalog.hypertable_compression_stats_for_schema(text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION _prom_catalog.hypertable_compression_stats_for_schema(text) to prom_reader;
END;
$block$
;

--------------------------------- Views --------------------------------

DO $block$
BEGIN
    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;

    CREATE OR REPLACE VIEW prom_info.metric AS
    WITH x AS
    (
        SELECT
            h.table_name,
            max(_timescaledb_internal.to_interval(d.interval_length)) AS chunk_interval,
            count(c.*) AS total_chunks,
            count(c.*) filter (where (c.status & 1) = 1) AS compressed_chunks,
            coalesce(sum(
                    CASE WHEN d.interval_length IS NOT NULL
                    THEN _timescaledb_internal.to_timestamp(ds.range_end) - _timescaledb_internal.to_timestamp(ds.range_start)
                    ELSE interval '0'
                    END
                ) filter (where (c.status & 1) = 1), interval '0') AS compressed_interval,
            coalesce(sum(
                    CASE WHEN d.interval_length IS NOT NULL
                    THEN _timescaledb_internal.to_timestamp(ds.range_end) - _timescaledb_internal.to_timestamp(ds.range_start)
                    ELSE interval '0'
                    END
                ), interval '0') AS total_interval
        FROM _timescaledb_catalog.hypertable h
        INNER JOIN _timescaledb_catalog.chunk c ON (h.id = c.hypertable_id)
        INNER JOIN _timescaledb_catalog.chunk_constraint k ON (c.id = k.chunk_id)
        INNER JOIN _timescaledb_catalog.dimension d ON (h.id = d.hypertable_id)
        INNER JOIN _timescaledb_catalog.dimension_slice ds ON (d.id = ds.dimension_id and k.dimension_slice_id = ds.id)
        WHERE h.schema_name = 'prom_data'
        AND c.dropped = false
        AND c.osm_chunk = false
        AND d.column_type::oid = 'timestamp with time zone'::regtype::oid
        AND d.column_name = 'time'
        GROUP BY h.table_name, d.id
    )
    SELECT
        m.id,
        m.metric_name,
        m.table_name::text as table_name,
        ARRAY(
            SELECT key
            FROM _prom_catalog.label_key_position lkp
            WHERE lkp.metric_name = m.metric_name
            ORDER BY key) label_keys,
        COALESCE(m.retention_period, _prom_catalog.get_default_retention_period()) as retention_period,
        x.chunk_interval,
        x.compressed_interval,
        x.total_interval,
        x.total_chunks::BIGINT AS total_chunks,
        x.compressed_chunks::BIGINT AS compressed_chunks
    FROM _prom_catalog.metric m
    LEFT OUTER JOIN x ON (m.table_name = x.table_name)
    ;
    GRANT SELECT ON prom_info.metric TO prom_reader;
END;
$block$;

CREATE OR REPLACE FUNCTION _prom_catalog.metric_detail()
RETURNS TABLE(id int, metric_name text, table_name text, label_keys text[], retention_period interval,
              chunk_interval interval, compressed_interval interval, total_interval interval,
              before_compression_bytes bigint, after_compression_bytes bigint,
              total_size_bytes bigint, total_size text, compression_ratio numeric,
              total_chunks bigint, compressed_chunks bigint)
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    IF _prom_catalog.is_multinode() THEN
        -- multinode
        RETURN QUERY
        SELECT
            m.id,
            m.metric_name,
            m.table_name,
            m.label_keys,
            m.retention_period,
            m.chunk_interval,
            m.compressed_interval,
            m.total_interval,
            hcs.before_compression_total_bytes::bigint AS before_compression_bytes,
            hcs.after_compression_total_bytes::bigint AS after_compression_bytes,
            hs.total_bytes::bigint as total_size_bytes,
            pg_size_pretty(hs.total_bytes::bigint) as total_size,
            (1.0 - (hcs.after_compression_total_bytes::NUMERIC / hcs.before_compression_total_bytes::NUMERIC)) * 100 as compression_ratio,
            m.total_chunks,
            m.compressed_chunks
        FROM prom_info.metric m
        LEFT JOIN
        (
            SELECT
              x.hypertable_name
            , sum(x.total_bytes::bigint) as total_bytes
            FROM
            (
                SELECT *
                FROM _prom_catalog.hypertable_local_size('prom_data')
                UNION ALL
                SELECT *
                FROM _prom_catalog.hypertable_remote_size('prom_data')
            ) x
            GROUP BY x.hypertable_name
        ) hs ON (hs.hypertable_name = m.table_name)
        LEFT JOIN _prom_catalog.hypertable_compression_stats_for_schema('prom_data') hcs ON (hcs.hypertable_name = m.table_name)
        ;
    ELSE
        -- singlenode
        RETURN QUERY
        WITH x AS
        (
            SELECT
                h.table_name,
                max(_timescaledb_internal.to_interval(d.interval_length)) AS chunk_interval,
                count(c.*) AS total_chunks,
                count(c.*) filter (where (c.status & 1) = 1) AS compressed_chunks,
                coalesce(sum(
                        CASE WHEN d.interval_length IS NOT NULL
                        THEN _timescaledb_internal.to_timestamp(ds.range_end) - _timescaledb_internal.to_timestamp(ds.range_start)
                        ELSE interval '0'
                        END
                    ) filter (where (c.status & 1) = 1), interval '0') AS compressed_interval,
                coalesce(sum(
                        CASE WHEN d.interval_length IS NOT NULL
                        THEN _timescaledb_internal.to_timestamp(ds.range_end) - _timescaledb_internal.to_timestamp(ds.range_start)
                        ELSE interval '0'
                        END
                    ), interval '0') AS total_interval,
                sum(z.uncompressed_heap_size + z.uncompressed_toast_size + z.uncompressed_index_size)::bigint as before_compression_bytes,
                sum(z.compressed_heap_size + z.compressed_toast_size + z.compressed_index_size)::bigint as after_compression_bytes,
                sum(
                    pg_total_relation_size(format('%I.%I'::text, c.schema_name, c.table_name)::regclass)
                    + coalesce(z.compressed_heap_size + z.compressed_toast_size + z.compressed_index_size, 0)
                ) as total_chunk_bytes
            FROM _timescaledb_catalog.hypertable h
            INNER JOIN _timescaledb_catalog.chunk c ON (h.id = c.hypertable_id)
            INNER JOIN _timescaledb_catalog.chunk_constraint k ON (c.id = k.chunk_id)
            INNER JOIN _timescaledb_catalog.dimension d ON (h.id = d.hypertable_id)
            INNER JOIN _timescaledb_catalog.dimension_slice ds ON (d.id = ds.dimension_id and k.dimension_slice_id = ds.id)
            LEFT OUTER JOIN _timescaledb_catalog.chunk cc ON (c.compressed_chunk_id = cc.id)
            LEFT OUTER JOIN _timescaledb_catalog.compression_chunk_size z ON (c.id = z.chunk_id)
            WHERE h.schema_name = 'prom_data'
            AND c.dropped = false
            AND c.osm_chunk = false
            AND d.column_type::oid = 'timestamp with time zone'::regtype::oid
            AND d.column_name = 'time'
            GROUP BY h.table_name, d.id
        )
        SELECT
            m.id,
            m.metric_name,
            m.table_name::text as table_name,
            ARRAY(
                SELECT key
                FROM _prom_catalog.label_key_position lkp
                WHERE lkp.metric_name = m.metric_name
                ORDER BY key) label_keys,
            COALESCE(m.retention_period, _prom_catalog.get_default_retention_period()) as retention_period,
            x.chunk_interval,
            x.compressed_interval,
            x.total_interval,
            x.before_compression_bytes,
            x.after_compression_bytes,
            (x.total_chunk_bytes + pg_total_relation_size(format('%I.%I'::text, 'prom_data', m.table_name)::regclass))::bigint as total_size_bytes,
            pg_size_pretty(x.total_chunk_bytes + pg_total_relation_size(format('%I.%I'::text, 'prom_data', m.table_name)::regclass)) as total_size,
            (1.0 - (x.after_compression_bytes::NUMERIC / x.before_compression_bytes::NUMERIC)) * 100 as compression_ratio,
            x.total_chunks::BIGINT AS total_chunks,
            x.compressed_chunks::BIGINT AS compressed_chunks
        FROM _prom_catalog.metric m
        LEFT OUTER JOIN x ON (m.table_name = x.table_name)
        ;
    END IF;
END;
$func$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION _prom_catalog.metric_detail() IS $$Returns details describing each metric table including disk sizes$$;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.metric_detail() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.metric_detail() TO prom_reader;

CREATE OR REPLACE VIEW prom_info.metric_detail AS
   SELECT * FROM _prom_catalog.metric_detail();
GRANT SELECT ON prom_info.metric_detail TO prom_reader;

CREATE OR REPLACE VIEW prom_info.label AS
    SELECT
        lk.key,
        lk.value_column_name,
        lk.id_column_name,
        va.values as values,
        cardinality(va.values) as num_values
    FROM _prom_catalog.label_key lk
    INNER JOIN LATERAL(SELECT key, array_agg(value ORDER BY value) as values FROM _prom_catalog.label GROUP BY key)
    AS va ON (va.key = lk.key) ORDER BY num_values DESC;
GRANT SELECT ON prom_info.label TO prom_reader;

CREATE OR REPLACE VIEW prom_info.system_stats AS
    SELECT
    (
        SELECT _prom_catalog.safe_approximate_row_count('_prom_catalog.series'::REGCLASS)
    ) AS num_series_approx,
    (
        SELECT count(*) FROM _prom_catalog.metric
    ) AS num_metric,
    (
        SELECT count(*) FROM _prom_catalog.label_key
    ) AS num_label_keys,
    (
        SELECT count(*) FROM _prom_catalog.label
    ) AS num_labels;
GRANT SELECT ON prom_info.system_stats TO prom_reader;

CREATE OR REPLACE VIEW prom_info.metric_stats AS
    SELECT metric_name,
    _prom_catalog.safe_approximate_row_count(format('prom_series.%I', table_name)::regclass) AS num_series_approx,
    (SELECT _prom_catalog.safe_approximate_row_count(format('prom_data.%I',table_name)::regclass)) AS num_samples_approx
    FROM _prom_catalog.metric ORDER BY metric_name;
GRANT SELECT ON prom_info.metric_stats TO prom_reader;

--this should the only thing run inside the transaction. It's important the txn ends after calling this function
--to release locks
CREATE OR REPLACE FUNCTION _prom_catalog.delay_compression_job(ht_table text, new_start timestamptz)
    RETURNS VOID
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    bgw_job_id int;
BEGIN
    UPDATE _prom_catalog.metric m
    SET delay_compression_until = new_start
    WHERE table_name = ht_table;

    IF _prom_catalog.get_timescale_major_version() < 2 THEN
        SELECT job_id INTO bgw_job_id
        FROM _timescaledb_config.bgw_policy_compress_chunks p
        INNER JOIN _timescaledb_catalog.hypertable h ON (h.id = p.hypertable_id)
        WHERE h.schema_name = 'prom_data' and h.table_name = ht_table;

        --alter job schedule is not currently concurrency-safe (timescaledb issue #2165)
        PERFORM pg_advisory_xact_lock(_prom_catalog.get_advisory_lock_prefix_job(), bgw_job_id);

        PERFORM public.alter_job_schedule(bgw_job_id, next_start=>GREATEST(new_start, (SELECT next_start FROM timescaledb_information.policy_stats WHERE job_id = bgw_job_id)));
    END IF;
END
$$
LANGUAGE PLPGSQL;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION _prom_catalog.delay_compression_job(text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.delay_compression_job(text, timestamptz) TO prom_writer;

CALL _prom_catalog.execute_everywhere('_prom_catalog.do_decompress_chunks_after', $ee$
DO $DO$
BEGIN
    --this function isolates the logic that needs to be security definer
    --cannot fold it into do_decompress_chunks_after because cannot have security
    --definer do txn-al stuff like commit
    CREATE OR REPLACE FUNCTION _prom_catalog.decompress_chunk_for_metric(metric_table TEXT, chunk_schema_name text, chunk_table_name text)
    RETURNS VOID
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $$
    DECLARE
        chunk_full_name text;
    BEGIN

       --double check chunk belongs to metric table
       SELECT
        format('%I.%I', c.schema_name, c.table_name)
       INTO chunk_full_name
       FROM _timescaledb_catalog.chunk c
       INNER JOIN  _timescaledb_catalog.hypertable h ON (h.id = c.hypertable_id)
       WHERE
            c.schema_name = chunk_schema_name AND c.table_name = chunk_table_name AND
            h.schema_name = 'prom_data' AND h.table_name = metric_table AND
            c.compressed_chunk_id IS NOT NULL;

        IF NOT FOUND Then
            RETURN;
        END IF;

       --lock the chunk exclusive.
       EXECUTE format('LOCK %I.%I;', chunk_schema_name, chunk_table_name);

       --double check it's still compressed.
       PERFORM c.*
       FROM _timescaledb_catalog.chunk c
       WHERE schema_name = chunk_schema_name AND table_name = chunk_table_name AND
       c.compressed_chunk_id IS NOT NULL;

       IF NOT FOUND Then
          RETURN;
       END IF;

       RAISE NOTICE 'Promscale is decompressing chunk: %.%', chunk_schema_name, chunk_table_name;
       PERFORM public.decompress_chunk(chunk_full_name);
    END;
    $$
    LANGUAGE PLPGSQL;
    REVOKE ALL ON FUNCTION _prom_catalog.decompress_chunk_for_metric(TEXT, text, text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION _prom_catalog.decompress_chunk_for_metric(TEXT, text, text) TO prom_writer;


    --Decompression should take place in a procedure because we don't want locks held across
    --decompress_chunk calls since that function takes some heavier locks at the end.
    --Thus, transactional parameter should usually be false
    CREATE OR REPLACE PROCEDURE _prom_catalog.do_decompress_chunks_after(metric_table TEXT, min_time TIMESTAMPTZ, transactional BOOLEAN = false)
    AS $$
    DECLARE
        chunk_row record;
        dimension_row record;
        hypertable_row record;
        min_time_internal bigint;
    BEGIN
        --note search_path cannot be set here because this is a proc that may be executed transactionally so schema qualify everything
        SELECT h.* INTO STRICT hypertable_row FROM _timescaledb_catalog.hypertable h
        WHERE h.table_name OPERATOR(pg_catalog.=) metric_table AND h.schema_name OPERATOR(pg_catalog.=) 'prom_data';

        SELECT d.* INTO STRICT dimension_row FROM _timescaledb_catalog.dimension d WHERE d.hypertable_id OPERATOR(pg_catalog.=) hypertable_row.id ORDER BY d.id LIMIT 1;

        IF min_time OPERATOR(pg_catalog.=) pg_catalog.timestamptz '-Infinity' THEN
            min_time_internal := -9223372036854775808;
        ELSE
           SELECT _timescaledb_internal.time_to_internal(min_time) INTO STRICT min_time_internal;
        END IF;

        FOR chunk_row IN
            SELECT c.*
            FROM _timescaledb_catalog.dimension_slice ds
            INNER JOIN _timescaledb_catalog.chunk_constraint cc ON cc.dimension_slice_id OPERATOR(pg_catalog.=) ds.id
            INNER JOIN _timescaledb_catalog.chunk c ON cc.chunk_id OPERATOR(pg_catalog.=) c.id
            WHERE ds.dimension_id OPERATOR(pg_catalog.=) dimension_row.id
            -- the range_ends are non-inclusive
            AND min_time_internal OPERATOR(pg_catalog.<) ds.range_end
            AND c.compressed_chunk_id IS NOT NULL
            ORDER BY ds.range_start
        LOOP
            PERFORM _prom_catalog.decompress_chunk_for_metric(metric_table, chunk_row.schema_name, chunk_row.table_name);
            IF NOT transactional THEN
              COMMIT;
              -- reset search path after transaction end. This is ok to do iff we are in transactional mode.
              SET LOCAL search_path = pg_catalog, pg_temp;
            END IF;
        END LOOP;
    END;
    $$ LANGUAGE PLPGSQL;
    GRANT EXECUTE ON PROCEDURE _prom_catalog.do_decompress_chunks_after(TEXT, TIMESTAMPTZ, BOOLEAN) TO prom_writer;
END
$DO$;
$ee$);

CREATE OR REPLACE PROCEDURE _prom_catalog.decompress_chunks_after(metric_table TEXT, min_time TIMESTAMPTZ, transactional BOOLEAN = false)
AS $proc$
BEGIN
    --do not set search path here since this can be called transactionally or not
    --make sure everything is schema qualified.

    -- In early versions of timescale multinode the access node catalog does not
    -- store whether chunks were compressed, so we need to run the actual search
    -- for nodes in need of decompression on the data nodes, and /not/ the
    -- access node; right now executing on the access node will do a lot of work
    -- and locking for no result.
    IF _prom_catalog.is_multinode() THEN
        CALL public.distributed_exec(
            pg_catalog.format(
                $dist$ CALL _prom_catalog.do_decompress_chunks_after(%L, %L, %L) $dist$,
                metric_table, min_time, transactional),
            transactional => false);
    ELSE
        CALL _prom_catalog.do_decompress_chunks_after(metric_table, min_time, transactional);
    END IF;
END
$proc$ LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.decompress_chunks_after(text, TIMESTAMPTZ, boolean) TO prom_writer;

CALL _prom_catalog.execute_everywhere('_prom_catalog.compress_old_chunks', $ee$
DO $DO$
BEGIN
    --this function isolates the logic that needs to be security definer
    --cannot fold it into compress_old_chunks because cannot have security
    --definer do txn-all stuff like commit
    CREATE OR REPLACE FUNCTION _prom_catalog.compress_chunk_for_hypertable(_hypertable_schema_name text, _hypertable_table_name text, _chunk_schema_name text, _chunk_table_name text)
    RETURNS VOID
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $$
    DECLARE
        chunk_full_name text;
    BEGIN
        SELECT
            format('%I.%I', ch.schema_name, ch.table_name)
        INTO chunk_full_name
        FROM _timescaledb_catalog.chunk ch
            JOIN _timescaledb_catalog.hypertable ht ON ht.id = ch.hypertable_id
        WHERE ht.schema_name IN ('prom_data', '_ps_trace') --for security, can only work on our tables
          AND ht.schema_name = _hypertable_schema_name
          AND ht.table_name = _hypertable_table_name
          AND ch.schema_name = _chunk_schema_name
          AND ch.table_name = _chunk_table_name;

        PERFORM public.compress_chunk(chunk_full_name, if_not_compressed => true);
    END;
    $$
    LANGUAGE PLPGSQL;
    REVOKE ALL ON FUNCTION _prom_catalog.compress_chunk_for_hypertable(text, text, text, text) FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION _prom_catalog.compress_chunk_for_hypertable(text, text, text, text) TO prom_maintenance;

    CREATE OR REPLACE PROCEDURE _prom_catalog.compress_old_chunks(_hypertable_schema_name TEXT, _hypertable_table_name TEXT, _compress_before TIMESTAMPTZ)
    AS $$
    DECLARE
        chunk_schema_name name;
        chunk_table_name name;
        chunk_range_end timestamptz;
        chunk_num INT;
    BEGIN
        -- Note: We cannot use SET in the procedure declaration because we do transaction control
        -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
        SET LOCAL search_path = pg_catalog, pg_temp;

        FOR chunk_schema_name, chunk_table_name, chunk_range_end, chunk_num IN
            SELECT
                ch.schema_name as chunk_schema,
                ch.table_name AS chunk_name,
                _timescaledb_internal.to_timestamp(dimsl.range_end) as range_end,
                row_number() OVER (ORDER BY dimsl.range_end DESC)
            FROM _timescaledb_catalog.chunk ch
                JOIN _timescaledb_catalog.hypertable ht ON ht.id = ch.hypertable_id
                JOIN _timescaledb_catalog.chunk_constraint chcons ON ch.id = chcons.chunk_id
                JOIN _timescaledb_catalog.dimension dim ON (ch.hypertable_id = dim.hypertable_id AND dim.column_name IN ('time', 'start_time','span_start_time'))
                JOIN _timescaledb_catalog.dimension_slice dimsl ON dim.id = dimsl.dimension_id AND chcons.dimension_slice_id = dimsl.id
            WHERE ch.dropped IS FALSE
                AND (ch.status & 1) != 1 -- only check for uncompressed chunks
                AND ht.schema_name = _hypertable_schema_name
                AND ht.table_name = _hypertable_table_name
            ORDER BY 3 ASC
        LOOP
            CONTINUE WHEN chunk_num <= 1 OR chunk_range_end > _compress_before;
            PERFORM _prom_catalog.compress_chunk_for_hypertable(_hypertable_schema_name, _hypertable_table_name, chunk_schema_name, chunk_table_name);
            COMMIT;
            -- reset search path after transaction end
            SET LOCAL search_path = pg_catalog, pg_temp;
        END LOOP;
    END;
    $$ LANGUAGE PLPGSQL;
    GRANT EXECUTE ON PROCEDURE _prom_catalog.compress_old_chunks(TEXT, TEXT, TIMESTAMPTZ) TO prom_maintenance;
END
$DO$;
$ee$);

CREATE OR REPLACE PROCEDURE _prom_catalog.compress_metric_chunks(metric_name TEXT)
AS $$
DECLARE
  metric_table NAME;
BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;

    SELECT table_name
    INTO STRICT metric_table
    FROM _prom_catalog.get_metric_table_name_if_exists('prom_data', metric_name);

    -- as of timescaledb-2.0-rc4 the is_compressed column of the chunks view is
    -- not updated on the access node, therefore we need to one the compressor
    -- on all the datanodes to search for uncompressed chunks
    IF _prom_catalog.is_multinode() THEN
        CALL public.distributed_exec(format($dist$
            CALL _prom_catalog.compress_old_chunks('prom_data', %L, now() - INTERVAL '1 hour')
        $dist$, metric_table), transactional => false);
    ELSE
        CALL _prom_catalog.compress_old_chunks('prom_data', metric_table, now() - INTERVAL '1 hour');
    END IF;
END
$$ LANGUAGE PLPGSQL;
GRANT EXECUTE ON PROCEDURE _prom_catalog.compress_metric_chunks(text) TO prom_maintenance;

--Order by random with stable marking gives us same order in a statement and different
-- orderings in different statements
CREATE OR REPLACE FUNCTION _prom_catalog.get_metrics_that_need_compression()
    RETURNS SETOF _prom_catalog.metric
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
BEGIN
        RETURN QUERY
        SELECT m.*
        FROM _prom_catalog.metric m
        WHERE
          is_view = false AND
          _prom_catalog.get_metric_compression_setting(m.metric_name) AND
          delay_compression_until IS NULL OR delay_compression_until < now() AND
          is_view = FALSE
        ORDER BY random();
END
$$
LANGUAGE PLPGSQL STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_metrics_that_need_compression() TO prom_maintenance;

--only for timescaledb 2.0 in 1.x we use compression policies
CREATE OR REPLACE PROCEDURE _prom_catalog.execute_compression_policy(log_verbose boolean = false)
AS $$
DECLARE
    r _prom_catalog.metric;
    remaining_metrics _prom_catalog.metric[] DEFAULT '{}';
    startT TIMESTAMPTZ;
    lockStartT TIMESTAMPTZ;
BEGIN
    -- Note: We cannot use SET in the procedure declaration because we do transaction control
    -- and we can _only_ use SET LOCAL in a procedure which _does_ transaction control
    SET LOCAL search_path = pg_catalog, pg_temp;

    --Do one loop with metric that could be locked without waiting.
    --This allows you to do everything you can while avoiding lock contention.
    --Then come back for the metrics that would have needed to wait on the lock.
    --Hopefully, that lock is now freed. The secoond loop waits for the lock
    --to prevent starvation.
    FOR r IN
        SELECT *
        FROM _prom_catalog.get_metrics_that_need_compression()
    LOOP
        IF NOT _prom_catalog.lock_metric_for_maintenance(r.id, wait=>false) THEN
            remaining_metrics := remaining_metrics OPERATOR(pg_catalog.||) r;
            CONTINUE;
        END IF;
        IF log_verbose THEN
            startT := pg_catalog.clock_timestamp();
            RAISE LOG 'promscale maintenance: compression: metric %: starting, without lock wait', r.metric_name;
        END IF;
        PERFORM _prom_catalog.set_app_name( pg_catalog.format('promscale maintenance: compression: metric %s', r.metric_name));
        CALL _prom_catalog.compress_metric_chunks(r.metric_name);
        IF log_verbose THEN
            RAISE LOG 'promscale maintenance: compression: metric %: finished in %', r.metric_name, pg_catalog.clock_timestamp() OPERATOR(pg_catalog.-) startT;
        END IF;
        PERFORM _prom_catalog.unlock_metric_for_maintenance(r.id);

        COMMIT;
        -- reset search path after transaction end
        SET LOCAL search_path = pg_catalog, pg_temp;
    END LOOP;

    FOR r IN
        SELECT *
        FROM pg_catalog.unnest(remaining_metrics)
    LOOP
        IF log_verbose THEN
            lockStartT := pg_catalog.clock_timestamp();
            RAISE LOG 'promscale maintenance: compression: metric %: waiting for lock', r.metric_name;
        END IF;
        PERFORM _prom_catalog.set_app_name( pg_catalog.format('promscale maintenance: compression: metric %s: waiting on lock', r.metric_name));
        PERFORM _prom_catalog.lock_metric_for_maintenance(r.id);
        IF log_verbose THEN
            startT := pg_catalog.clock_timestamp();
            RAISE LOG 'promscale maintenance: compression: metric %: starting', r.metric_name;
        END IF;
        PERFORM _prom_catalog.set_app_name( pg_catalog.format('promscale maintenance: compression: metric %s', r.metric_name));
        CALL _prom_catalog.compress_metric_chunks(r.metric_name);
        IF log_verbose THEN
            RAISE LOG 'promscale maintenance: compression: metric %: finished in % (lock took %; compression took %)', r.metric_name, pg_catalog.clock_timestamp() OPERATOR(pg_catalog.-) lockStartT, startT OPERATOR(pg_catalog.-) lockStartT, pg_catalog.clock_timestamp() OPERATOR(pg_catalog.-) startT;
        END IF;
        PERFORM _prom_catalog.unlock_metric_for_maintenance(r.id);

        COMMIT;
        -- reset search path after transaction end
        SET LOCAL search_path = pg_catalog, pg_temp;
    END LOOP;
END;
$$ LANGUAGE PLPGSQL;
COMMENT ON PROCEDURE _prom_catalog.execute_compression_policy(boolean)
IS 'compress data according to the policy. This procedure should be run regularly in a cron job';
GRANT EXECUTE ON PROCEDURE _prom_catalog.execute_compression_policy(boolean) TO prom_maintenance;

CREATE OR REPLACE PROCEDURE prom_api.add_prom_node(node_name TEXT, attach_to_existing_metrics BOOLEAN = true)
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    command_row record;
BEGIN
    FOR command_row IN
        SELECT command, transactional
        FROM _prom_catalog.remote_commands
        ORDER BY seq asc
    LOOP
        CALL public.distributed_exec(command_row.command,node_list=>array[node_name]);
    END LOOP;

    IF attach_to_existing_metrics THEN
        PERFORM public.attach_data_node(node_name, hypertable => format('%I.%I', 'prom_data', table_name))
        FROM _prom_catalog.metric;
    END IF;
END
$func$ LANGUAGE PLPGSQL;
-- add_prom_node is a superuser only function

CREATE OR REPLACE FUNCTION _prom_catalog.insert_metric_row(
    metric_table text,
    time_array timestamptz[],
    value_array DOUBLE PRECISION[],
    series_id_array bigint[]
)
    RETURNS BIGINT
    SET search_path = pg_catalog, pg_temp
AS
$$
DECLARE
  num_rows BIGINT;
BEGIN
    --turns out there is a horrible CPU perf penalty on the DB for ON CONFLICT DO NOTHING.
    --yet in our data, conflicts are rare. So we first try inserting without ON CONFLICT
    --and fall back if there is a unique constraint violation.
    EXECUTE FORMAT(
     'INSERT INTO  prom_data.%1$I (time, value, series_id)
          SELECT * FROM unnest($1, $2, $3) a(t,v,s) ORDER BY s,t',
        metric_table
    ) USING time_array, value_array, series_id_array;
    GET DIAGNOSTICS num_rows = ROW_COUNT;
    RETURN num_rows;
EXCEPTION WHEN unique_violation THEN
	EXECUTE FORMAT(
	'INSERT INTO  prom_data.%1$I (time, value, series_id)
		 SELECT * FROM unnest($1, $2, $3) a(t,v,s) ORDER BY s,t ON CONFLICT DO NOTHING',
	   metric_table
	) USING time_array, value_array, series_id_array;
	GET DIAGNOSTICS num_rows = ROW_COUNT;
	RETURN num_rows;
END;
$$
LANGUAGE PLPGSQL;
GRANT EXECUTE ON FUNCTION _prom_catalog.insert_metric_row(TEXT, TIMESTAMPTZ[], DOUBLE PRECISION[], BIGINT[]) TO prom_writer;

-- Creates a temporary table (if it doesn't exist) used for ingestion of metrics and traces
-- Suppresses corresponding DDL logging, otherwise PG log may get unnecessarily verbose.
-- Temporary table is created using supplied table and schema as prototype.
-- Returns temporary table name
CREATE OR REPLACE FUNCTION _prom_catalog.create_ingest_temp_table(table_name TEXT, schema_name TEXT, table_prefix TEXT)
    RETURNS TEXT
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    temp_table TEXT;
BEGIN
    SET LOCAL log_statement = 'none';
    temp_table := left(CONCAT(table_prefix, table_name), 62);
    EXECUTE format($sql$CREATE TEMPORARY TABLE IF NOT EXISTS %I (LIKE %I.%I) ON COMMIT DELETE ROWS$sql$,
                 temp_table, schema_name, table_name);
    EXECUTE format($sql$GRANT SELECT, INSERT ON TABLE %I TO prom_writer$sql$,
                 temp_table);
    RETURN temp_table;
END;
$func$
LANGUAGE plpgsql;
REVOKE ALL ON FUNCTION _prom_catalog.create_ingest_temp_table(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _prom_catalog.create_ingest_temp_table(TEXT, TEXT, TEXT) TO prom_writer;
COMMENT ON FUNCTION _prom_catalog.create_ingest_temp_table
IS 'Creates a temporary table (if it doesn''t exist) used for ingestion of metrics or traces.
Temporary table is created using supplied table and schema as prototype.
Suppresses corresponding DDL logging, otherwise PG log may get unnecessarily verbose.
Api user has to make sure that table_prefix is unique per session/connection.
This is to prevent different truncated table names having same temp table.
Returns temporary table name';
