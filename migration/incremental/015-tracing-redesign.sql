-- Due to incompatible change of trace_id type we need to drop tables and delete data
DROP TABLE _ps_trace.link CASCADE;
DROP TABLE _ps_trace.event CASCADE;
DROP TABLE _ps_trace.span CASCADE;
DROP TABLE _ps_trace.tag CASCADE;
--need to drop because of enum redefinition
DROP TABLE _ps_trace.operation;
/* XXX We drop these views because they depend on some changes ahead
 * Although they should be dropped by now due to commands above, it's
 * better to be explicit here.
 */
DROP VIEW IF EXISTS ps_trace.event CASCADE;
DROP VIEW IF EXISTS ps_trace.link CASCADE;
DROP VIEW IF EXISTS ps_trace.span CASCADE;

DELETE FROM _ps_trace.tag_key WHERE id >= 1000;
ANALYZE _ps_trace.tag_key;
REINDEX TABLE _ps_trace.tag_key;
PERFORM setval('_ps_trace.tag_key_id_seq', 1000);

TRUNCATE TABLE _ps_trace.instrumentation_lib CASCADE;
ANALYZE _ps_trace.instrumentation_lib;
TRUNCATE TABLE _ps_trace.schema_url CASCADE;
ANALYZE _ps_trace.schema_url;

CREATE TABLE _ps_trace.tag (
    id BIGINT NOT NULL GENERATED ALWAYS AS IDENTITY,
    key_id BIGINT NOT NULL,
    tag_type ps_trace.tag_type NOT NULL,
    key ps_trace.tag_k NOT NULL REFERENCES _ps_trace.tag_key (key) ON DELETE CASCADE,
    value ps_trace.tag_v NOT NULL
);
CREATE UNIQUE INDEX tag_key_value_id_key_id_key_idx ON _ps_trace.tag (key, _prom_ext.jsonb_digest(value)) INCLUDE (id, key_id);
GRANT SELECT ON TABLE _ps_trace.tag TO prom_reader;
REVOKE ALL PRIVILEGES ON TABLE _ps_trace.tag FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.tag TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.tag TO prom_modifier;

--redefine enums to be more user friendly
DROP TYPE ps_trace.span_kind CASCADE;
CREATE TYPE ps_trace.span_kind AS ENUM
(
    'unspecified',
    'internal',
    'server',
    'client',
    'producer',
    'consumer'
);
GRANT USAGE ON TYPE ps_trace.span_kind TO prom_reader;

DROP TYPE ps_trace.status_code CASCADE;
CREATE TYPE ps_trace.status_code AS ENUM
(
    'unset',
    'ok',
    'error'
);
GRANT USAGE ON TYPE ps_trace.status_code TO prom_reader;

CREATE TABLE IF NOT EXISTS _ps_trace.operation
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_name_id bigint not null, -- references id column of tag table for the service.name tag value
    span_kind ps_trace.span_kind not null,
    span_name text NOT NULL CHECK (span_name != ''),
    UNIQUE (service_name_id, span_name, span_kind)
);
GRANT SELECT ON TABLE _ps_trace.operation TO prom_reader;
REVOKE ALL PRIVILEGES ON TABLE _ps_trace.operation FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.operation TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.operation TO prom_modifier;
GRANT USAGE ON SEQUENCE _ps_trace.operation_id_seq TO prom_modifier, prom_writer;

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

-- ps_trace.trace_id and uuid are binary coercible
CREATE CAST(ps_trace.trace_id as uuid) WITHOUT FUNCTION AS IMPLICIT;
CREATE CAST(uuid AS ps_trace.trace_id) WITHOUT FUNCTION AS IMPLICIT;
/* Drop the old tag_map type */
DROP DOMAIN ps_trace.tag_map CASCADE;

DROP FUNCTION IF EXISTS _ps_trace.eval_tags_by_key(ps_trace.tag_k);
DROP FUNCTION IF EXISTS _ps_trace.eval_jsonb_path_exists(ps_tag.tag_op_jsonb_path_exists);
DROP FUNCTION IF EXISTS _ps_trace.eval_regexp_matches(ps_tag.tag_op_regexp_matches);
DROP FUNCTION IF EXISTS _ps_trace.eval_regexp_not_matches(ps_tag.tag_op_regexp_not_matches);
DROP FUNCTION IF EXISTS _ps_trace.eval_equals(ps_tag.tag_op_equals);
DROP FUNCTION IF EXISTS _ps_trace.eval_not_equals(ps_tag.tag_op_not_equals);
DROP FUNCTION IF EXISTS _ps_trace.eval_less_than(ps_tag.tag_op_less_than);
DROP FUNCTION IF EXISTS _ps_trace.eval_less_than_or_equal(ps_tag.tag_op_less_than_or_equal);
DROP FUNCTION IF EXISTS _ps_trace.eval_greater_than(ps_tag.tag_op_greater_than);
DROP FUNCTION IF EXISTS _ps_trace.eval_greater_than_or_equal(ps_tag.tag_op_greater_than_or_equal);

/* Define custom tag_map and tag_v json aliases
 * NOTE: We need to keep an eye on upstream jsonb type
 * and keep these up-to-date.
 */

CREATE TYPE ps_trace.tag_map;
CREATE TYPE _ps_trace.tag_v;

CREATE OR REPLACE FUNCTION ps_trace.tag_map_in(cstring)
RETURNS ps_trace.tag_map
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_in$function$
;

CREATE OR REPLACE FUNCTION ps_trace.tag_map_out(ps_trace.tag_map)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_out$function$
;

CREATE OR REPLACE FUNCTION ps_trace.tag_map_send(ps_trace.tag_map)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_send$function$
;

CREATE OR REPLACE FUNCTION ps_trace.tag_map_recv(internal)
RETURNS ps_trace.tag_map
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_recv$function$
;

DO
$do$

/* Create subscript_handler function for pg v14+ and the type accordingly.
 * For pg v13 jsonb type doesn't have a subscript_handler function so it shall
 * be omitted.
 */
DECLARE
    _pg_version int4 := current_setting('server_version_num')::int4;
BEGIN
    SET search_path = pg_catalog;
    IF (_pg_version >= 140000) THEN
        CREATE OR REPLACE FUNCTION ps_trace.tag_map_subscript_handler(internal)
                RETURNS internal
                LANGUAGE internal
                IMMUTABLE PARALLEL SAFE STRICT
                AS $f$jsonb_subscript_handler$f$;

        CREATE TYPE ps_trace.tag_map (
                INPUT = ps_trace.tag_map_in,
                OUTPUT = ps_trace.tag_map_out,
                SEND = ps_trace.tag_map_send,
                RECEIVE = ps_trace.tag_map_recv,
                SUBSCRIPT = ps_trace.tag_map_subscript_handler);

    ELSE
            CREATE TYPE ps_trace.tag_map (
                INPUT = ps_trace.tag_map_in,
                OUTPUT = ps_trace.tag_map_out,
                SEND = ps_trace.tag_map_send,
                RECEIVE = ps_trace.tag_map_recv);

    END IF;
END
$do$;


CREATE CAST (jsonb AS ps_trace.tag_map) WITHOUT FUNCTION AS IMPLICIT;
CREATE CAST (ps_trace.tag_map AS jsonb) WITHOUT FUNCTION AS IMPLICIT;

CREATE CAST (json AS ps_trace.tag_map) WITH INOUT AS ASSIGNMENT;
CREATE CAST (ps_trace.tag_map AS json) WITH INOUT AS ASSIGNMENT;

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_in(cstring)
RETURNS _ps_trace.tag_v
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_in$function$
;

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_out(_ps_trace.tag_v)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_out$function$
;

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_send(_ps_trace.tag_v)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_send$function$
;

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_recv(internal)
RETURNS _ps_trace.tag_v
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_recv$function$
;

DO
$do$

/* Create subscript_handler function for pg v14+ and the type accordingly.
 * For pg v13 jsonb type doesn't have a subscript_handler function so it shall
 * be omitted.
 */
DECLARE
    _pg_version int4 := pg_catalog.current_setting('server_version_num')::int4;
BEGIN
    SET search_path = pg_catalog;
    IF (_pg_version >= 140000) THEN
        CREATE OR REPLACE FUNCTION _ps_trace.tag_v_subscript_handler(internal)
                RETURNS internal
                LANGUAGE internal
                IMMUTABLE PARALLEL SAFE STRICT
                AS $f$jsonb_subscript_handler$f$;

        CREATE TYPE _ps_trace.tag_v (
                INPUT = _ps_trace.tag_v_in,
                OUTPUT = _ps_trace.tag_v_out,
                SEND = _ps_trace.tag_v_send,
                RECEIVE = _ps_trace.tag_v_recv,
                SUBSCRIPT = _ps_trace.tag_v_subscript_handler);
    ELSE
        CREATE TYPE _ps_trace.tag_v (
            INPUT = _ps_trace.tag_v_in,
            OUTPUT = _ps_trace.tag_v_out,
            SEND = _ps_trace.tag_v_send,
            RECEIVE = _ps_trace.tag_v_recv);

    END IF;
END
$do$;

GRANT USAGE ON TYPE ps_trace.tag_map TO prom_reader;
GRANT USAGE ON TYPE _ps_trace.tag_v TO prom_reader;

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
CREATE INDEX ON _ps_trace.span USING GIN (resource_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
GRANT SELECT ON TABLE _ps_trace.span TO prom_reader;
REVOKE ALL PRIVILEGES ON TABLE _ps_trace.span FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.span TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.span TO prom_modifier;

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
REVOKE ALL PRIVILEGES ON TABLE _ps_trace.event FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.event TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.event TO prom_modifier;

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
REVOKE ALL PRIVILEGES ON TABLE _ps_trace.link FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.link TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.link TO prom_modifier;

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
    _is_restore_in_progress boolean = false;
BEGIN

    IF NOT _prom_catalog.is_timescaledb_installed() THEN
        RETURN;
    END IF;

    _is_restore_in_progress = coalesce(
        (SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF _is_restore_in_progress THEN
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
            EXECUTE format($sql$ALTER EXTENSION promscale DROP TABLE %I.%I;$sql$, _rec.schema_name, _rec.table_name);
        END LOOP;

    END IF;
END;
$block$
;

REVOKE ALL PRIVILEGES ON TABLE _ps_trace.tag FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT, UPDATE ON TABLE _ps_trace.tag TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.tag TO prom_modifier;
GRANT USAGE ON SEQUENCE _ps_trace.tag_id_seq TO prom_writer, prom_modifier;

REVOKE ALL PRIVILEGES ON TABLE _ps_trace.tag_key FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT, UPDATE ON TABLE _ps_trace.tag_key TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.tag_key TO prom_modifier;
GRANT USAGE ON SEQUENCE _ps_trace.tag_key_id_seq TO prom_writer, prom_modifier;

REVOKE ALL PRIVILEGES ON TABLE _ps_trace.operation FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.operation TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.operation TO prom_modifier;
GRANT USAGE ON SEQUENCE _ps_trace.operation_id_seq TO prom_writer, prom_modifier;

REVOKE ALL PRIVILEGES ON TABLE _ps_trace.schema_url FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.schema_url TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.schema_url TO prom_modifier;
GRANT USAGE ON SEQUENCE _ps_trace.schema_url_id_seq TO prom_writer, prom_modifier;

REVOKE ALL PRIVILEGES ON TABLE _ps_trace.instrumentation_lib FROM prom_writer; -- prev migration granted too many privileges
GRANT SELECT, INSERT ON TABLE _ps_trace.instrumentation_lib TO prom_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.instrumentation_lib TO prom_modifier;
GRANT USAGE ON SEQUENCE _ps_trace.instrumentation_lib_id_seq TO prom_writer, prom_modifier;
