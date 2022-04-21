CREATE OR REPLACE FUNCTION _prom_catalog.get_timescale_major_version()
    RETURNS INT
    SET search_path = pg_catalog
AS $func$
    SELECT split_part(extversion, '.', 1)::INT FROM pg_catalog.pg_extension WHERE extname='timescaledb' LIMIT 1;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _prom_catalog.get_timescale_minor_version()
    RETURNS INT
    SET search_path = pg_catalog
AS $func$
    SELECT split_part(extversion, '.', 2)::INT FROM pg_catalog.pg_extension WHERE extname='timescaledb' LIMIT 1;
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.get_timescale_minor_version() TO prom_reader;

--just a stub will be replaced in the idempotent scripts
CREATE OR REPLACE PROCEDURE _prom_catalog.execute_maintenance_job(job_id int, config jsonb)
AS $$
BEGIN
    RAISE 'calling execute_maintenance_job stub, should have been replaced';
END
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION _prom_catalog.is_timescaledb_installed()
    RETURNS BOOLEAN
    SET search_path = pg_catalog
AS $func$
    SELECT count(*) > 0 FROM pg_extension WHERE extname='timescaledb';
$func$
LANGUAGE SQL STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.is_timescaledb_installed() TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.is_timescaledb_oss()
    RETURNS BOOLEAN
    SET search_path = pg_catalog
AS
$$
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
    SET search_path = pg_catalog
AS $func$
    SELECT count(*) > 0 FROM timescaledb_information.data_nodes
$func$
LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION _prom_catalog.is_multinode() TO prom_reader;

--add 2 jobs executing every 30 min by default for timescaledb 2.0
DO $$
DECLARE
    _is_restore_in_progress boolean = false;
BEGIN
    _is_restore_in_progress = coalesce((SELECT setting = 'on' from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF  NOT _prom_catalog.is_timescaledb_oss()
        AND _prom_catalog.get_timescale_major_version() >= 2
        AND NOT _is_restore_in_progress
        THEN
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min');
       PERFORM public.add_job('_prom_catalog.execute_maintenance_job', '30 min');
    END IF;
END
$$;
