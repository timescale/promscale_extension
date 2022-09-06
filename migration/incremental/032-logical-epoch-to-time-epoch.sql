CREATE TABLE _prom_catalog.global_epoch (
    current_epoch TIMESTAMPTZ NOT NULL,
    delete_epoch TIMESTAMPTZ NOT NULL,
    -- force there to only be a single row
    is_unique BOOLEAN NOT NULL DEFAULT true CHECK (is_unique = true),
    UNIQUE (is_unique)
);
GRANT SELECT ON TABLE _prom_catalog.global_epoch TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.global_epoch TO prom_writer;

DO $block$
    DECLARE
        _is_restore_in_progress boolean = false;
    BEGIN
        _is_restore_in_progress = coalesce((SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
        IF _is_restore_in_progress THEN
            -- if a restore is in progress, we want the value from the backup, not this hardcoded init value
            RAISE NOTICE 'restore in progress. skipping insert into _prom_catalog.global_epoch';
            RETURN;
        END IF;
        -- this ensures that pristine and migrated DBs have the same values
        -- it's also important that current_epoch > delete_epoch
        INSERT INTO _prom_catalog.global_epoch (current_epoch, delete_epoch, is_unique)
            VALUES ('2020-01-01 00:00:00 UTC', '1970-01-01 00:00:00 UTC', true);
    END;
$block$;

ALTER TABLE _prom_catalog.series ADD COLUMN
    mark_for_deletion_epoch TIMESTAMPTZ NULL DEFAULT NULL;

-- We're changing the signature of epoch_abort, it will be recreated in the
-- idempotent migration script.
DROP FUNCTION IF EXISTS _prom_catalog.epoch_abort(BIGINT);

DROP FUNCTION IF EXISTS _prom_catalog.delete_expired_series(text, text, text, timestamptz, BIGINT, timestamptz);

UPDATE _prom_catalog.series s
SET mark_for_deletion_epoch = now() -- NOTE: we can't use current_epoch because we've initialized it to a value in the past
FROM (SELECT current_epoch FROM _prom_catalog.global_epoch) as global_epoch
WHERE s.delete_epoch IS NOT NULL;

DROP TABLE _prom_catalog.ids_epoch;
-- This cascades to the prom_series.<metric_name> views
ALTER TABLE _prom_catalog.series DROP COLUMN delete_epoch CASCADE;

DO $block$
    DECLARE
        _rec record;
        label_value_cols text;
    BEGIN
        FOR _rec IN (
            SELECT * FROM _prom_catalog.metric
            WHERE table_schema = 'prom_data'
        )
        LOOP
            -- Add partial index on mark_for_deletion epoch for all existing partitions of _prom_catalog.series
            EXECUTE format($$
                CREATE INDEX IF NOT EXISTS
                    series_mark_for_deletion_epoch_id_%s
                ON prom_data_series.%I (mark_for_deletion_epoch, id)
                WHERE mark_for_deletion_epoch IS NOT NULL
                $$, _rec.id, _rec.table_name);

            -- Drop the prom_series views
            EXECUTE format('DROP VIEW IF EXISTS prom_series.%1$I', _rec.table_name);

            -- Note: we cannot use `_prom_catalog.create_series_view` here because it has not been updated yet,
            -- so we are forced to copy the relevant part of the method body here
            SELECT
                ',' || string_agg(
                    format ('prom_api.val(series.labels[%s]) AS %I',pos::int, _prom_catalog.get_label_key_column_name_for_view(key, false))
                , ', ' ORDER BY pos)
            INTO STRICT label_value_cols
            FROM _prom_catalog.label_key_position lkp
            WHERE lkp.metric_name = _rec.metric_name and key != '__name__';

            EXECUTE FORMAT($$
                CREATE OR REPLACE VIEW prom_series.%1$I AS
                SELECT
                    id AS series_id,
                    labels
                    %2$s
                FROM
                    prom_data_series.%1$I AS series
                WHERE mark_for_deletion_epoch IS NULL
                $$, _rec.metric_name, label_value_cols);

            EXECUTE FORMAT('GRANT SELECT ON prom_series.%1$I TO prom_reader', _rec.metric_name);
            EXECUTE FORMAT('ALTER VIEW prom_series.%1$I OWNER TO prom_admin', _rec.metric_name);

            -- The views that we recreated belong to the extension, which we don't want.
            -- So we drop them from the extension.
            EXECUTE FORMAT('ALTER EXTENSION promscale DROP VIEW prom_series.%1$I', _rec.metric_name);
        END LOOP;
    END;
$block$;
