
-- we changed the datatypes (name → text) used in these function signatures
-- need to drop the old versions
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_local_size(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_node_up(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_compression_stats_for_schema(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.hypertable_remote_size(name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.metric_view() CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.get_new_pos_for_key(text, name, text[], boolean) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.delete_series_catalog_row(name, bigint[]) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.get_or_create_label_ids(TEXT, NAME, text[], text[]) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.get_or_create_label_ids(text, name, text[], text[]) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.create_series(int, NAME, prom_api.label_array, OUT BIGINT) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.resurrect_series_ids(name, bigint) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.get_or_create_series_id_for_label_array(INT, NAME, prom_api.label_array, OUT BIGINT) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.get_confirmed_unused_series(NAME, NAME, NAME, BIGINT[], TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS prom_api.register_metric_view(name, name, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS prom_api.unregister_metric_view(name, name, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.delay_compression_job(name, timestamptz) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.decompress_chunk_for_metric(TEXT, name, name) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.do_decompress_chunks_after(NAME, TIMESTAMPTZ, BOOLEAN) CASCADE;
DROP PROCEDURE IF EXISTS _prom_catalog.decompress_chunks_after(NAME, TIMESTAMPTZ, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.compress_chunk_for_hypertable(name, name, name, name) CASCADE;
DROP PROCEDURE IF EXISTS _prom_catalog.compress_old_chunks(NAME, NAME, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.insert_metric_row(name, timestamptz[], DOUBLE PRECISION[], bigint[]) CASCADE;
DROP FUNCTION IF EXISTS _prom_catalog.insert_exemplar_row(NAME, TIMESTAMPTZ[], BIGINT[], prom_api.label_value_array[], DOUBLE PRECISION[]) CASCADE;
DROP PROCEDURE IF EXISTS _ps_trace.execute_tracing_compression(name, BOOLEAN) CASCADE;
