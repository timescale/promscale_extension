ALTER TABLE _prom_catalog.ids_epoch ADD COLUMN
    delete_epoch BIGINT NULL DEFAULT NULL;

-- We will reinitialize the value of `current_epoch` anyway, so it's easier to
-- start from a common base.
UPDATE _prom_catalog.ids_epoch SET current_epoch = 0 WHERE current_epoch <> 0;

-- We're changing the signatures of these functions, so they must be dropped.
DROP FUNCTION IF EXISTS _prom_catalog.mark_series_to_be_dropped_as_unused(TEXT, TEXT, TEXT, TIMESTAMPTZ);
DROP PROCEDURE IF EXISTS _prom_catalog.drop_metric_chunks(TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN);

-- We're replacing this function with a procedure, so it must be dropped.
DROP FUNCTION IF EXISTS _prom_catalog.delete_expired_series(TEXT, TEXT, TEXT, TIMESTAMPTZ, BIGINT, TIMESTAMPTZ);

