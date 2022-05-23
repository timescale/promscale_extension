-- stop all background workers in the current db so they don't interfere
-- with the upgrade (by e.g. holding locks).
--
-- Note: this stops the scheduler (and thus all jobs)
-- and waits for the current txn (the one doing the upgrade) to finish
-- before starting it up again. Thus, no jobs will be running during
-- the upgrade.

-- TimescaleDB itself does the same thing:
-- https://github.com/timescale/timescaledb/blob/72d03e6f7d30cc4794c9263445f14199241e2eb5/sql/updates/pre-update.sql#L34
DO
$stop_bgw$
DECLARE
    _is_timescaledb_installed boolean = false;
BEGIN
    SELECT count(*) > 0
    INTO STRICT _is_timescaledb_installed
    FROM pg_extension
    WHERE extname='timescaledb';

    IF _is_timescaledb_installed THEN
        PERFORM _timescaledb_internal.restart_background_workers();
    END IF;
END;
$stop_bgw$;
