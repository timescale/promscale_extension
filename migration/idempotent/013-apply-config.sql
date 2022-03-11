
DO $block$
DECLARE
    _schema text;
BEGIN
    FOR _schema IN
    (
        values
          ('_prom_catalog')
        , ('_prom_ext')
        , ('_ps_catalog')
        , ('_ps_trace')
        , ('prom_api')
        , ('prom_data')
        , ('prom_data_exemplar')
        , ('prom_data_series')
        , ('prom_info')
        , ('prom_metric')
        , ('prom_series')
        , ('ps_tag')
        , ('ps_trace')
    )
    LOOP
        EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC', _schema);
        EXECUTE format('REVOKE ALL ON ALL PROCEDURES IN SCHEMA %I FROM PUBLIC', _schema);
    END LOOP;
END;
$block$;

DO $block$
DECLARE
    _table text;
BEGIN
    FOR _table IN
    (
        values
          ('_prom_catalog.default')
        , ('_prom_catalog.exemplar')
        , ('_prom_catalog.exemplar_label_key_position')
        , ('_prom_catalog.ha_leases')
        , ('_prom_catalog.ha_leases_logs')
        , ('_prom_catalog.ids_epoch')
        , ('_prom_catalog.label')
        , ('_prom_catalog.label_key')
        , ('_prom_catalog.label_key_position')
        , ('_prom_catalog.metadata')
        , ('_prom_catalog.metric')
        , ('_prom_catalog.remote_commands')
        , ('_prom_catalog.series')
        , ('_ps_catalog.migration')
        , ('_ps_catalog.promscale_instance_information')
        , ('_ps_trace.event')
        , ('_ps_trace.instrumentation_lib')
        , ('_ps_trace.link')
        , ('_ps_trace.operation')
        , ('_ps_trace.schema_url')
        , ('_ps_trace.span')
        , ('_ps_trace.tag')
        , ('_ps_trace.tag_key')
        , ('public.prom_installation_info')
    )
    LOOP
        EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump(%L, '')$sql$, _table);
    END LOOP;
END;
$block$;

DO $block$
DECLARE
    _i bigint;
    _max bigint = 64;
BEGIN
    FOR _i IN 1.._max
    LOOP
        EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump('_ps_trace.tag_%s', '')$sql$, _i);
   END LOOP;
END
$block$
;

-- TODO (james): possibly move these grants closer to their definitions? At
--  definition time, the roles which we grant here haven't been created yet.
GRANT EXECUTE ON FUNCTION _prom_ext.num_cpus() TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_delta(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_increase(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_rate(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.vector_selector(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.update_tsprom_metadata(TEXT, TEXT, BOOLEAN) TO prom_writer;
GRANT EXECUTE ON FUNCTION _prom_ext.rewrite_fn_call_to_subquery(internal) TO prom_reader;
GRANT EXECUTE ON PROCEDURE _prom_catalog.execute_everywhere(text, text, boolean) TO prom_admin;
GRANT EXECUTE ON PROCEDURE _prom_catalog.update_execute_everywhere_entry(text, text, boolean) TO prom_admin;
GRANT SELECT ON TABLE _prom_catalog.remote_commands TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.remote_commands TO prom_admin;
GRANT SELECT ON TABLE _ps_catalog.migration TO prom_reader;
