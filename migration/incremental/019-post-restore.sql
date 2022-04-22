
CREATE FUNCTION public.promscale_post_restore()
RETURNS void
SECURITY DEFINER
SET search_path = pg_catalog
AS $func$
DECLARE
BEGIN
    CREATE TRIGGER ts_insert_blocker
    BEFORE INSERT ON _ps_trace.span
    FOR EACH ROW EXECUTE FUNCTION _timescaledb_internal.insert_blocker();

    CREATE TRIGGER ts_insert_blocker
    BEFORE INSERT ON _ps_trace.event
    FOR EACH ROW EXECUTE FUNCTION _timescaledb_internal.insert_blocker();

    CREATE TRIGGER ts_insert_blocker
    BEFORE INSERT ON _ps_trace.link
    FOR EACH ROW EXECUTE FUNCTION _timescaledb_internal.insert_blocker();
END
$func$
LANGUAGE PLPGSQL VOLATILE;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION public.promscale_post_restore() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.promscale_post_restore() TO prom_admin;
COMMENT ON FUNCTION public.promscale_post_restore()
IS 'Performs required setup tasks after restoring the database from a logical backup';
