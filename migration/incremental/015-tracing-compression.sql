-- Due to incompatible change of trace_id type we need to drop tables and delete data
DROP TABLE _ps_trace.link CASCADE;
DROP TABLE _ps_trace.event CASCADE;
DROP TABLE _ps_trace.span CASCADE;

TRUNCATE TABLE _ps_trace.tag;
DELETE FROM _ps_trace.tag_key WHERE id >= 1000;
ANALYZE _ps_trace.tag_key;
REINDEX TABLE _ps_trace.tag_key;
PERFORM setval('_ps_trace.tag_key_id_seq', 1000);
TRUNCATE TABLE _ps_trace.operation;
ANALYZE _ps_trace.operation;
TRUNCATE TABLE _ps_trace.instrumentation_lib CASCADE;
ANALYZE _ps_trace.instrumentation_lib;
TRUNCATE TABLE _ps_trace.schema_url CASCADE;
ANALYZE _ps_trace.schema_url;

ALTER TABLE _ps_trace.tag DROP CONSTRAINT tag_key_value_id_key_id_key;
CREATE UNIQUE INDEX tag_key_value_id_key_id_key ON _ps_trace.tag (key, _prom_ext.jsonb_digest(value)) INCLUDE (id, key_id);

-- We are replacing domain with custom type
DROP DOMAIN ps_trace.trace_id CASCADE;

CREATE TYPE ps_trace.trace_id;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_in(cstring)
RETURNS ps_trace.trace_id
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_in$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_in(cstring) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_out(ps_trace.trace_id)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_out$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_out(ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_send(ps_trace.trace_id)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_send$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_send(ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_recv(internal)
RETURNS ps_trace.trace_id
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_recv$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_recv(internal) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_ne(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_ne$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_ne(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_eq(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_eq$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_eq(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_ge(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_ge$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_ge(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_le(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_le$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_le(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_gt(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_gt$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_gt(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_lt(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_lt$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_lt(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_cmp(ps_trace.trace_id, ps_trace.trace_id)
RETURNS int
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_cmp$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_cmp(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_hash(ps_trace.trace_id)
RETURNS int
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_hash$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_hash(ps_trace.trace_id) TO prom_reader;

CREATE TYPE ps_trace.trace_id(
    internallength = 16,
    INPUT = _ps_trace.trace_id_in,
    OUTPUT = _ps_trace.trace_id_out,
    SEND = _ps_trace.trace_id_send,
    RECEIVE = _ps_trace.trace_id_recv,
    alignment = char
);

CREATE OPERATOR ps_trace.= (
    FUNCTION=_ps_trace.trace_id_eq,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.=),
    NEGATOR= OPERATOR(ps_trace.!=),
    RESTRICT=eqsel,
    JOIN=eqjoinsel,
    HASHES, MERGES);

CREATE OPERATOR ps_trace.<> (
    FUNCTION=_ps_trace.trace_id_ne,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.<>),
    NEGATOR= OPERATOR(ps_trace.=),
    RESTRICT=neqsel,
    JOIN=neqjoinsel);

CREATE OPERATOR ps_trace.> (
    FUNCTION=_ps_trace.trace_id_gt,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.<),
    NEGATOR= OPERATOR(ps_trace.<=),
    RESTRICT=scalargtsel,
    JOIN=scalargtjoinsel);

CREATE OPERATOR ps_trace.>= (
    FUNCTION=_ps_trace.trace_id_ge,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.<=),
    NEGATOR= OPERATOR(ps_trace.<),
    RESTRICT=scalargesel,
    JOIN=scalargejoinsel);

CREATE OPERATOR ps_trace.< (
    FUNCTION=_ps_trace.trace_id_lt,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.>),
    NEGATOR= OPERATOR(ps_trace.>=),
    RESTRICT=scalarltsel,
    JOIN=scalarltjoinsel);

CREATE OPERATOR ps_trace.<= (
    FUNCTION=_ps_trace.trace_id_le,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.>=),
    NEGATOR= OPERATOR(ps_trace.>),
    RESTRICT=scalarlesel,
    JOIN=scalarlejoinsel);

CREATE OPERATOR CLASS ps_trace.btree_trace_id_ops
DEFAULT FOR TYPE ps_trace.trace_id USING btree AS
    OPERATOR        1       ps_trace.< ,
    OPERATOR        2       ps_trace.<= ,
    OPERATOR        3       ps_trace.= ,
    OPERATOR        4       ps_trace.>= ,
    OPERATOR        5       ps_trace.> ,
    FUNCTION 1 _ps_trace.trace_id_cmp(ps_trace.trace_id,ps_trace.trace_id);

CREATE OPERATOR CLASS ps_trace.hash_trace_id_ops
DEFAULT FOR TYPE ps_trace.trace_id USING hash AS
    OPERATOR 1 ps_trace.=,
    FUNCTION 1 _ps_trace.trace_id_hash(ps_trace.trace_id);

GRANT USAGE ON TYPE ps_trace.trace_id TO prom_reader;


CREATE TABLE _ps_trace.span
(
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL, /* not allowed to be 0 */
    parent_span_id bigint NULL, /* if set not allowed be 0 */
    operation_id bigint NOT NULL,
    start_time timestamptz NOT NULL,
    end_time timestamptz NOT NULL,
    duration_ms double precision NOT NULL,
    instrumentation_lib_id bigint,
    resource_schema_url_id bigint,
    event_time tstzrange default NULL,
    dropped_tags_count int NOT NULL default 0,
    dropped_events_count int NOT NULL default 0,
    dropped_link_count int NOT NULL default 0,
    resource_dropped_tags_count int NOT NULL default 0,
    status_code ps_trace.status_code NOT NULL,
    trace_state text, /* empty string not allowed */
    span_tags ps_trace.tag_map NOT NULL,
    status_message text,
    resource_tags ps_trace.tag_map NOT NULL,
    PRIMARY KEY (span_id, trace_id, start_time)
);
CREATE INDEX ON _ps_trace.span USING BTREE (trace_id, parent_span_id) INCLUDE (span_id); -- used for recursive CTEs for trace tree queries
CREATE INDEX ON _ps_trace.span USING GIN (span_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
CREATE INDEX ON _ps_trace.span USING BTREE (operation_id); -- supports filters/joins to operation table
--CREATE INDEX ON _ps_trace.span USING GIN (jsonb_object_keys(span_tags) array_ops); -- possible way to index key exists
CREATE INDEX ON _ps_trace.span USING GIN (resource_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
GRANT SELECT ON TABLE _ps_trace.span TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.span TO prom_writer;

CREATE TABLE _ps_trace.event
(
    time timestamptz NOT NULL,
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL, /* not allowed to be 0 */
    event_nbr int NOT NULL DEFAULT 0,
    dropped_tags_count int NOT NULL DEFAULT 0,
    name text NOT NULL,
    tags ps_trace.tag_map NOT NULL
);
CREATE INDEX ON _ps_trace.event USING GIN (tags jsonb_path_ops);
CREATE INDEX ON _ps_trace.event USING BTREE (trace_id, span_id);
GRANT SELECT ON TABLE _ps_trace.event TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.event TO prom_writer;

CREATE TABLE _ps_trace.link
(
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL,
    span_start_time timestamptz NOT NULL,
    linked_trace_id ps_trace.trace_id NOT NULL,
    linked_span_id bigint NOT NULL, /* not allowed to be 0 */
    link_nbr int NOT NULL DEFAULT 0,
    dropped_tags_count int NOT NULL DEFAULT 0,
    trace_state text, /* empty string not allowed */
    tags ps_trace.tag_map NOT NULL
);
CREATE INDEX ON _ps_trace.link USING BTREE (trace_id, span_id);
CREATE INDEX ON _ps_trace.link USING GIN (tags jsonb_path_ops);
GRANT SELECT ON TABLE _ps_trace.link TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.link TO prom_writer;

/*
    If "vanilla" postgres is installed, do nothing.
    If timescaledb is installed, turn on compression for tracing tables.
    If timescaledb is installed and multinode is set up,
    turn span, event, and link into distributed hypertables.
    If timescaledb is installed but multinode is NOT set up,
    turn span, event, and link into regular hypertables.
*/
DO $block$
DECLARE
    _is_compression_available boolean = false;
    _rec record;
BEGIN
    IF _prom_catalog.is_restore_in_progress() THEN
        RETURN;
    END IF;

    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;

    IF _prom_catalog.is_multinode() THEN
        PERFORM public.create_distributed_hypertable(
            '_ps_trace.span'::regclass,
            'start_time'::name,
            partitioning_column=>'trace_id'::name,
            number_partitions=>1::int,
            chunk_time_interval=>'1 hours'::interval,
            create_default_indexes=>false
        );
        PERFORM public.create_distributed_hypertable(
            '_ps_trace.event'::regclass,
            'time'::name,
            partitioning_column=>'trace_id'::name,
            number_partitions=>1::int,
            chunk_time_interval=>'1 hours'::interval,
            create_default_indexes=>false
        );
        PERFORM public.create_distributed_hypertable(
            '_ps_trace.link'::regclass,
            'span_start_time'::name,
            partitioning_column=>'trace_id'::name,
            number_partitions=>1::int,
            chunk_time_interval=>'1 hours'::interval,
            create_default_indexes=>false
        );
    ELSE -- not multinode
        PERFORM public.create_hypertable(
            '_ps_trace.span'::regclass,
            'start_time'::name,
            partitioning_column=>'trace_id'::name,
            number_partitions=>1::int,
            chunk_time_interval=>'1 hours'::interval,
            create_default_indexes=>false
        );
        PERFORM public.create_hypertable(
            '_ps_trace.event'::regclass,
            'time'::name,
            partitioning_column=>'trace_id'::name,
            number_partitions=>1::int,
            chunk_time_interval=>'1 hours'::interval,
            create_default_indexes=>false
        );
        PERFORM public.create_hypertable(
            '_ps_trace.link'::regclass,
            'span_start_time'::name,
            partitioning_column=>'trace_id'::name,
            number_partitions=>1::int,
            chunk_time_interval=>'1 hours'::interval,
            create_default_indexes=>false
        );
    END IF;

    _is_compression_available = NOT (current_setting('timescaledb.license') = 'apache');
    IF _is_compression_available THEN
        -- turn on compression
        ALTER TABLE _ps_trace.span SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,start_time');
        ALTER TABLE _ps_trace.event SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,time');
        ALTER TABLE _ps_trace.link SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,span_start_time');

        PERFORM public.add_compression_policy('_ps_trace.span', INTERVAL '1 hours');
        PERFORM public.add_compression_policy('_ps_trace.event', INTERVAL '1 hours');
        PERFORM public.add_compression_policy('_ps_trace.link', INTERVAL '1 hours');

        -- we do not want the compressed hypertables to be associated with the extension
        -- we want both the table definitions and data to be dumped by pg_dump
        -- we cannot call create_hypertable during the restore, so we want the definitions in the dump
        FOR _rec IN
        (
            SELECT c.schema_name, c.table_name
            FROM _timescaledb_catalog.hypertable h
            INNER JOIN _timescaledb_catalog.hypertable c
            ON (h.compressed_hypertable_id = c.id)
            WHERE h.schema_name = '_ps_trace'
            AND h.table_name IN ('span', 'link', 'event')
        )
        LOOP
            RAISE NOTICE 'removing %.% from extension', _rec.schema_name, _rec.table_name;
            EXECUTE format($sql$ALTER EXTENSION promscale DROP TABLE %I.%I;$sql$, _rec.schema_name, _rec.table_name);
        END LOOP;

    END IF;
END;
$block$
;
