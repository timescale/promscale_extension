ALTER TABLE _prom_catalog.series OWNER TO prom_admin;

GRANT SELECT ON TABLE _prom_catalog.remote_commands TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.remote_commands TO prom_admin;
GRANT SELECT ON TABLE _ps_catalog.migration TO prom_reader;

GRANT EXECUTE ON FUNCTION _prom_ext.num_cpus() TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.jsonb_digest(JSONB) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_delta(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_increase(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.prom_rate(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.vector_selector(TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, TIMESTAMPTZ, DOUBLE PRECISION) TO prom_reader;
GRANT EXECUTE ON FUNCTION _prom_ext.rewrite_fn_call_to_subquery(internal) TO prom_reader;

GRANT EXECUTE ON PROCEDURE _prom_catalog.execute_everywhere(text, text, boolean) TO prom_admin;
GRANT EXECUTE ON PROCEDURE _prom_catalog.update_execute_everywhere_entry(text, text, boolean) TO prom_admin;
