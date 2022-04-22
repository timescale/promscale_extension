
CREATE FUNCTION public.promscale_post_restore()
RETURNS void
SECURITY DEFINER
SET search_path = pg_catalog
AS $func$
DECLARE
    _sql text;
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

    SELECT format('ALTER TABLE _ps_trace.tag_key ALTER COLUMN id RESTART WITH %s', max(id) + 1)
    INTO STRICT _sql
    FROM _ps_trace.tag_key;
    EXECUTE _sql;

    SELECT format('ALTER TABLE _ps_trace.tag ALTER COLUMN id RESTART WITH %s', max(id) + 1)
    INTO STRICT _sql
    FROM _ps_trace.tag;
    EXECUTE _sql;

    SELECT format('ALTER TABLE _ps_trace.schema_url ALTER COLUMN id RESTART WITH %s', max(id) + 1)
    INTO STRICT _sql
    FROM _ps_trace.schema_url;
    EXECUTE _sql;

    SELECT format('ALTER TABLE _ps_trace.instrumentation_lib ALTER COLUMN id RESTART WITH %s', max(id) + 1)
    INTO STRICT _sql
    FROM _ps_trace.instrumentation_lib;
    EXECUTE _sql;

    SELECT format('ALTER TABLE _ps_trace.operation ALTER COLUMN id RESTART WITH %s', max(id) + 1)
    INTO STRICT _sql
    FROM _ps_trace.operation;
    EXECUTE _sql;

END
$func$
LANGUAGE PLPGSQL VOLATILE;
--redundant given schema settings but extra caution for security definers
REVOKE ALL ON FUNCTION public.promscale_post_restore() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.promscale_post_restore() TO prom_admin;
COMMENT ON FUNCTION public.promscale_post_restore()
IS 'Performs required setup tasks after restoring the database from a logical backup';
