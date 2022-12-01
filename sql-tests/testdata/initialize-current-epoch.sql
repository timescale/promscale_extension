\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(5);

CREATE FUNCTION test_initialize_current_epoch()
    RETURNS SETOF TEXT
    LANGUAGE plpgsql VOLATILE AS
$fnc$
DECLARE
    now_ts TIMESTAMPTZ;
    now_epoch_s BIGINT;
BEGIN
    now_ts := now();
    now_epoch_s := EXTRACT (EPOCH FROM now_ts);
    RETURN NEXT is(current_epoch, 0::BIGINT) FROM _prom_catalog.ids_epoch;
    RETURN NEXT is(_prom_catalog.initialize_current_epoch(now_ts), now_epoch_s);
    RETURN NEXT is(current_epoch, now_epoch_s) FROM _prom_catalog.ids_epoch;
    RETURN NEXT is(_prom_catalog.initialize_current_epoch(now_ts + '1 minute'::interval), now_epoch_s);
    RETURN NEXT is(current_epoch, now_epoch_s) FROM _prom_catalog.ids_epoch;
    RETURN;
END;
$fnc$;

SELECT test_initialize_current_epoch();

-- The end
SELECT * FROM finish(true);