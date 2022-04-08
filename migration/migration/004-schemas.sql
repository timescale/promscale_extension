-- Note: This whole block of schema creation was previously run in an
-- execute_everywhere block, which would have broken either single-node or
-- multi-node installs. By removing the execute_everywhere we have definitely
-- broken multi-node, but single-node is intact. The tracking issue for this
-- is: https://github.com/timescale/promscale_extension/issues/187

-- _prom_catalog is created before
GRANT USAGE ON SCHEMA _prom_catalog TO prom_reader;

CREATE SCHEMA prom_api; -- public functions
GRANT USAGE ON SCHEMA prom_api TO prom_reader;

-- _prom_ext is created by postgres on extension creation
GRANT USAGE ON SCHEMA _prom_ext TO prom_reader;

CREATE SCHEMA prom_series; -- series views
GRANT USAGE ON SCHEMA prom_series TO prom_reader;

CREATE SCHEMA prom_metric; -- metric views
GRANT USAGE ON SCHEMA prom_metric TO prom_reader;

CREATE SCHEMA prom_data;
GRANT USAGE ON SCHEMA prom_data TO prom_reader;

CREATE SCHEMA prom_data_series;
GRANT USAGE ON SCHEMA prom_data_series TO prom_reader;

CREATE SCHEMA prom_info;
GRANT USAGE ON SCHEMA prom_info TO prom_reader;

CREATE SCHEMA prom_data_exemplar;
GRANT USAGE ON SCHEMA prom_data_exemplar TO prom_reader;
GRANT ALL ON SCHEMA prom_data_exemplar TO prom_writer;

CREATE SCHEMA ps_tag;
GRANT USAGE ON SCHEMA ps_tag TO prom_reader;

CREATE SCHEMA _ps_trace;
GRANT USAGE ON SCHEMA _ps_trace TO prom_reader;

CREATE SCHEMA ps_trace;
GRANT USAGE ON SCHEMA ps_trace TO prom_reader;

-- _ps_catalog is created before
GRANT USAGE ON SCHEMA _ps_catalog TO prom_reader;

-- the promscale extension contains optimized version of some
-- of our functions and operators. To ensure the correct version of the are
-- used, _prom_ext must be before all of our other schemas in the search path
DO $$
DECLARE
   new_path text;
BEGIN
   new_path := current_setting('search_path') || format(',%L,%L,%L,%L,%L,%L', 'ps_tag', '_prom_ext', 'prom_api', 'prom_metric', '_prom_catalog', 'ps_trace');
   execute format('ALTER DATABASE %I SET search_path = %s', current_database(), new_path);
   execute format('SET search_path = %s', new_path);
END
$$;
